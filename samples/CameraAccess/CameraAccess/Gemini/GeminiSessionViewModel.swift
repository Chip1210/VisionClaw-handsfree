import Foundation
import SwiftUI

@MainActor
class GeminiSessionViewModel: ObservableObject {
  @Published var isGeminiActive: Bool = false
  @Published var connectionState: GeminiConnectionState = .disconnected
  @Published var isModelSpeaking: Bool = false
  @Published var errorMessage: String?
  @Published var userTranscript: String = ""
  @Published var aiTranscript: String = ""
  @Published var toolCallStatus: ToolCallStatus = .idle
  @Published var openClawConnectionState: OpenClawConnectionState = .notConfigured
  @Published var lastVoiceToVoiceMs: Int?
  @Published var localBargeInFlash = false
  /// nil until capture starts; then whether hardware echo cancellation engaged
  /// this session. Shown on screen because it varies run to run on this beta.
  @Published var echoCancellationOn: Bool?
  private let geminiService = GeminiLiveService()
  private let openClawBridge = OpenClawBridge()
  private var toolCallRouter: ToolCallRouter?
  private var cameraStillProvider: (() async -> UIImage?)?
  private let audioManager = AudioManager()
  private let eventClient = OpenClawEventClient()
  private var lastVideoFrameTime: Date = .distantPast
  private var stateObservation: Task<Void, Never>?

  var streamingMode: StreamingMode = .glasses
  /// Last close reason the socket reported, so a failed connect can say why.
  private var lastCloseReason: String?

  func startSession() async {
    guard !isGeminiActive else { return }

    guard GeminiConfig.isConfigured else {
      errorMessage = "Gemini API key not configured. Open GeminiConfig.swift and replace YOUR_GEMINI_API_KEY with your key from https://aistudio.google.com/apikey"
      return
    }

    isGeminiActive = true
    lastCloseReason = nil

    // Wire audio callbacks
    audioManager.onAudioCaptured = { [weak self] data in
      guard let self else { return }
      Task { @MainActor in
        // With hardware echo cancellation the mic streams continuously and the
        // server's VAD owns turn-taking -- that is what makes interruption
        // work. Without it (VPIO unsupported or failed), the raw loudspeaker
        // feed reaches the model as its own voice, so fall back to half-duplex:
        // mute while it speaks. Worse than barge-in, but never a feedback loop.
        let speakerOnPhone = self.streamingMode == .iPhone || SettingsManager.shared.speakerOutputEnabled
        if speakerOnPhone && !self.audioManager.echoCancellationActive
          && self.audioManager.isSpeakerActive { return }
        self.geminiService.sendAudio(data: data)
      }
    }

    geminiService.onAudioReceived = { [weak self] data in
      self?.audioManager.playAudio(data: data)
    }

    geminiService.onReady = { [weak self] in
      self?.audioManager.playReadyTone()
    }

    audioManager.onVoiceToVoiceLatency = { [weak self] seconds in
      Task { @MainActor in self?.lastVoiceToVoiceMs = Int(seconds * 1000) }
    }

    audioManager.onLocalBargeIn = { [weak self] in
      Task { @MainActor in
        self?.localBargeInFlash = true
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        self?.localBargeInFlash = false
      }
    }

    geminiService.onInterrupted = { [weak self] in
      self?.audioManager.stopPlayback()
    }

    geminiService.onTurnComplete = { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        // Clear user transcript when AI finishes responding
        self.userTranscript = ""
      }
    }

    geminiService.onInputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.userTranscript = Self.tidyCJK(self.userTranscript + text)
        self.aiTranscript = ""
      }
    }

    geminiService.onOutputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.aiTranscript = Self.tidyCJK(self.aiTranscript + text)
      }
    }

    // Handle unexpected disconnection
    geminiService.onDisconnected = { [weak self] reason in
      guard let self else { return }
      Task { @MainActor in
        self.lastCloseReason = reason
        guard self.isGeminiActive else { return }
        self.stopSession()
        self.errorMessage = "Connection lost: \(reason ?? "Unknown error")"
      }
    }

    // Check OpenClaw connectivity and start fresh session
    await openClawBridge.checkConnection()
    openClawBridge.resetSession()

    // Wire tool call handling
    toolCallRouter = ToolCallRouter(bridge: openClawBridge)
    wireCameraIntoRouter()

    geminiService.onToolCall = { [weak self] toolCall in
      guard let self else { return }
      Task { @MainActor in
        for call in toolCall.functionCalls {
          self.toolCallRouter?.handleToolCall(call) { [weak self] response in
            self?.geminiService.sendToolResponse(response)
          }
        }
      }
    }

    geminiService.onToolCallCancellation = { [weak self] cancellation in
      guard let self else { return }
      Task { @MainActor in
        self.toolCallRouter?.cancelToolCalls(ids: cancellation.ids)
      }
    }

    // Observe service state
    stateObservation = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        guard !Task.isCancelled else { break }
        self.connectionState = self.geminiService.connectionState
        self.isModelSpeaking = self.geminiService.isModelSpeaking
        self.toolCallStatus = self.openClawBridge.lastToolCallStatus
        self.openClawConnectionState = self.openClawBridge.connectionState
      }
    }

    // Standby already has the capture unit running: just move the route to
    // the glasses. This is the only path that works from the lock screen.
    let fromStandby = audioManager.standbyActive && streamingMode == .glasses
    if fromStandby {
      audioManager.activateFromStandby()
      // Give the hands-free Bluetooth link a moment to come up.
      try? await Task.sleep(nanoseconds: 1_200_000_000)
      echoCancellationOn = audioManager.echoCancellationActive
    } else {
      if audioManager.standbyActive { audioManager.endStandby() }
      // Setup audio
      do {
        try audioManager.setupAudioSession(useIPhoneMode: streamingMode == .iPhone)
      } catch {
        errorMessage = "Audio setup failed: \(error.localizedDescription)"
        isGeminiActive = false
        return
      }
    }

    // Start mic capture BEFORE the network round trip. Running audio I/O is
    // what keeps the app alive when a session is started from the lock screen
    // (capture-button double press); if the socket connect comes first, iOS
    // suspends the app mid-handshake and nothing ever starts. Audio captured
    // before the socket is ready is dropped by sendAudio, so the order is safe.
    // From the lock screen the glasses' hands-free audio link is still coming
    // up when the first start is attempted and Core Audio refuses it with
    // "unspecified" (2003329396). Give the link a few seconds, retrying the
    // whole audio bring-up each time, before giving up.
    var captureError: Error?
    for attempt in 1...6 where !fromStandby {
      do {
        if attempt > 1 {
          try? await Task.sleep(nanoseconds: 1_000_000_000)
          try audioManager.setupAudioSession(useIPhoneMode: streamingMode == .iPhone)
        }
        try audioManager.startCapture()
        echoCancellationOn = audioManager.echoCancellationActive
        captureError = nil
        if attempt > 1 { NSLog("[Audio] Capture started on attempt %d", attempt) }
        break
      } catch {
        captureError = error
        NSLog("[Audio] Capture start attempt %d failed: %@", attempt, error.localizedDescription)
      }
    }
    if let captureError {
      errorMessage = "Mic capture failed: \(captureError.localizedDescription)"
      stateObservation?.cancel()
      stateObservation = nil
      isGeminiActive = false
      connectionState = .disconnected
      return
    }

    // Connect to Gemini and wait for setupComplete
    let setupOk = await geminiService.connect()

    if !setupOk {
      let msg: String
      if case .error(let err) = geminiService.connectionState {
        msg = err
      } else if let closeReason = lastCloseReason {
        msg = "Gemini closed the connection: \(closeReason)"
      } else {
        msg = "Failed to connect to Gemini"
      }
      NSLog("[Gemini] Connect failed: %@", msg)
      errorMessage = msg
      // Keep the mic path alive for the next lock-screen attempt.
      if fromStandby || SettingsManager.shared.handsFreeStandbyEnabled && streamingMode == .glasses {
        audioManager.returnToStandby()
      } else {
        audioManager.stopCapture()
      }
      geminiService.disconnect()
      stateObservation?.cancel()
      stateObservation = nil
      isGeminiActive = false
      connectionState = .disconnected
      return
    }

    // Connect to OpenClaw event stream for proactive notifications
    if SettingsManager.shared.proactiveNotificationsEnabled {
      eventClient.onNotification = { [weak self] text in
        guard let self else { return }
        Task { @MainActor in
          guard self.isGeminiActive, self.connectionState == .ready else { return }
          self.geminiService.sendTextMessage(text)
        }
      }
      eventClient.connect()
    }
  }

  /// Live transcription arrives in word-segmented chunks with separator
  /// spaces, ASR-style. Between Latin words that is correct; between CJK
  /// characters it renders as arbitrary gaps mid-sentence. Collapse spaces
  /// whose both neighbors are CJK (or CJK punctuation), keep the rest --
  /// "Hypervolt Go 3" stays spaced, "你手里 拿的" does not.
  static func tidyCJK(_ text: String) -> String {
    text.replacingOccurrences(
      of: "(?<=[\\p{Han}\\u3000-\\u303F\\uFF00-\\uFF65])\\s+(?=[\\p{Han}\\u3000-\\u303F\\uFF00-\\uFF65])",
      with: "",
      options: .regularExpression)
  }

  func stopSession() {
    openClawBridge.flushSessionContext()
    eventClient.disconnect()
    toolCallRouter?.cancelAll()
    toolCallRouter = nil
    if SettingsManager.shared.handsFreeStandbyEnabled, streamingMode == .glasses {
      audioManager.returnToStandby()
    } else {
      audioManager.stopCapture()
    }
    geminiService.disconnect()
    stateObservation?.cancel()
    stateObservation = nil
    isGeminiActive = false
    connectionState = .disconnected
    isModelSpeaking = false
    userTranscript = ""
    aiTranscript = ""
    toolCallStatus = .idle
    echoCancellationOn = nil
  }

  /// Let look_closely reach the camera. Called by whoever owns both view models;
  /// until it is, the tool reports that no camera is available rather than hanging.
  /// Held on the view model, not written straight to the router: the router is
  /// built in startSession() and discarded on stop, while this is called once
  /// when the view appears. Assigning directly would land on a nil router and
  /// silently do nothing.
  /// Open the microphone path in standby so a capture-button press can start
  /// a conversation from the lock screen. Must be called while the app is in
  /// the foreground; iOS refuses to start capture from the background.
  var isInStandby: Bool { audioManager.standbyActive }

  @MainActor
  func enterStandbyIfPossible() {
    guard SettingsManager.shared.handsFreeStandbyEnabled else {
      audioManager.endStandby()
      return
    }
    guard !isGeminiActive, streamingMode == .glasses, !audioManager.standbyActive,
          !audioManager.isCapturingAudio,
          UIApplication.shared.applicationState == .active else { return }
    do {
      try audioManager.enterStandby()
    } catch {
      NSLog("[Audio] Standby failed: %@", error.localizedDescription)
    }
  }

  func attachCamera(captureStill: @escaping () async -> UIImage?) {
    cameraStillProvider = captureStill
    wireCameraIntoRouter()
  }

  /// Glasses capture button: hand Gemini a sharp still and ask it to describe
  /// it aloud. The image goes over the realtime channel (as look_closely does)
  /// and the text turn makes the model answer instead of silently absorbing it.
  func describeStill(_ image: UIImage) {
    guard isGeminiActive, connectionState == .ready else { return }
    geminiService.sendVideoFrame(image: image, quality: GeminiConfig.stillJPEGQuality)
    geminiService.sendTextMessage(
      "I just pressed the capture button on my glasses to take a photo of what I'm looking at. "
      + "Look at the sharp photo that just arrived and tell me what you see. If there is text, "
      + "read it out. Keep it short unless the detail matters.")
  }

  private func wireCameraIntoRouter() {
    guard let router = toolCallRouter, let provider = cameraStillProvider else { return }
    router.captureStill = provider
    router.sendStill = { [weak self] image in
      self?.geminiService.sendVideoFrame(image: image, quality: GeminiConfig.stillJPEGQuality)
    }
  }

  func sendVideoFrameIfThrottled(image: UIImage) {
    guard SettingsManager.shared.videoStreamingEnabled else { return }
    guard isGeminiActive, connectionState == .ready else { return }
    let now = Date()
    guard now.timeIntervalSince(lastVideoFrameTime) >= GeminiConfig.videoFrameInterval else { return }
    lastVideoFrameTime = now
    geminiService.sendVideoFrame(image: image)
  }

}
