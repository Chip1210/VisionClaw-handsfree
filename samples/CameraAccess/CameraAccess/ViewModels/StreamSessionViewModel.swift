/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionViewModel.swift
//
// Core view model demonstrating video streaming from Meta wearable devices using the DAT SDK.
// This class showcases the key streaming patterns: device selection, session management,
// video frame handling, photo capture, and error handling.
//
// DAT 1.0 model: a DeviceSession is created and started first, then a Camera is
// added to it and its Stream carries the video. The old single StreamSession
// object (DAT 0.4) is gone; this view model keeps the same public surface so
// the views and the Gemini bridge are unchanged.
//

import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import MWDATCamera
import MWDATCore
import MWDATInputs
import Photos
import SwiftUI
import VideoToolbox

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

enum StreamingMode {
  case glasses
  case iPhone
}

@MainActor
class StreamSessionViewModel: ObservableObject {
  @Published var currentVideoFrame: UIImage?
  @Published var hasReceivedFirstFrame: Bool = false
  @Published var streamingStatus: StreamingStatus = .stopped
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""
  @Published var hasActiveDevice: Bool = false
  @Published var streamingMode: StreamingMode = .glasses
  @Published var selectedResolution: StreamingResolution = .high

  var isStreaming: Bool {
    streamingStatus != .stopped
  }

  var resolutionLabel: String {
    switch selectedResolution {
    case .low: return "360x640"
    case .medium: return "504x896"
    case .high: return "720x1280"
    @unknown default: return "Unknown"
    }
  }

  // Photo capture properties
  @Published var capturedPhoto: UIImage?
  @Published var showPhotoPreview: Bool = false

  // Gemini Live integration
  var geminiSessionVM: GeminiSessionViewModel?

  // DAT 1.0 splits the old StreamSession into a DeviceSession (the connection to
  // the glasses) and a Camera whose `stream` carries the video. Both are nil when
  // the Wearables SDK is unavailable (simulator, or a build without glasses); the
  // iPhone camera path never touches them.
  private var deviceSession: DeviceSession?
  private var camera: Camera?
  // Glasses input events (capture button). The session is kept open whenever
  // glasses are around so a double press of the capture button can start and
  // stop the Gemini conversation without touching the phone.
  private var inputs: Inputs?
  private var inputsEventsTask: Task<Void, Never>?
  private var inputsStateToken: AnyListenerToken?
  private var inputsErrorToken: AnyListenerToken?
  private var sessionRetryTask: Task<Void, Never>?
  // A double press arrives as two short presses followed by a doublePress
  // event; a single-press action must wait that out so it does not fire twice
  // on the way to a double press.
  private var pendingSinglePress: Task<Void, Never>?
  private var singlePressInFlight = false
  // A freshly added camera's stream reports `.stopped` before `.starting`.
  // Acting on that flips streamingStatus to .stopped for a moment, which
  // unmounts StreamView, whose onDisappear ends the whole conversation.
  private var streamHasStarted = false
  // Set when the user asked to stream; the session state observer starts the
  // camera as soon as the session reaches `.started`, since a camera can only be
  // added to a started session.
  private var wantsStream: Bool = false
  // Listener tokens are used to manage DAT SDK event subscriptions
  private var sessionStateListenerToken: AnyListenerToken?
  private var sessionErrorListenerToken: AnyListenerToken?
  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?
  private let wearables: WearablesInterface?
  private let deviceSelector: AutoDeviceSelector?
  private var deviceMonitorTask: Task<Void, Never>?
  private var iPhoneCameraManager: IPhoneCameraManager?

  // Requested glasses frame rate. Gemini only samples one frame a second (see
  // GeminiConfig.videoFrameInterval), so a low rate costs nothing there and
  // gives each frame more of the limited Bluetooth bandwidth, i.e. less
  // per-frame compression and sharper frames for the model to read. The
  // glasses may clamp this up to their own floor; the fps log below reports
  // the rate actually delivered.
  private let requestedFrameRate: UInt = 5
  private var fpsCount: Int = 0
  private var fpsWindowStart: Date = .now

  /// Non-nil in iPhone mode: lets the view draw an AVCaptureVideoPreviewLayer
  /// off the live session instead of upscaling the converted frames.
  var iPhoneCaptureSession: AVCaptureSession? { iPhoneCameraManager?.session }

  /// Shown while pinching, and reset when the camera stops.
  @Published var iPhoneZoom: CGFloat = 1
  /// Zoom when the current pinch began; a magnification gesture reports scale
  /// relative to its own start, not to the last committed value.
  private var zoomAtGestureStart: CGFloat = 1

  var maxIPhoneZoom: CGFloat { iPhoneCameraManager?.maxAvailableZoom ?? 1 }

  func beginIPhoneZoomGesture() {
    zoomAtGestureStart = iPhoneZoom
  }

  func updateIPhoneZoom(scale: CGFloat) {
    guard let camera = iPhoneCameraManager else { return }
    let target = min(max(zoomAtGestureStart * scale, 1), camera.maxAvailableZoom)
    iPhoneZoom = target
    camera.setZoom(target)
  }

  // CPU-based CIContext for rendering decoded pixel buffers in background
  private let cpuCIContext = CIContext(options: [.useSoftwareRenderer: true])
  // VideoDecoder for decompressing HEVC/H.264 frames in background
  private let videoDecoder = VideoDecoder()
  private var backgroundFrameCount = 0
  private var bgDiagLogged = false

  init(wearables: WearablesInterface?) {
    self.wearables = wearables

    if let wearables {
      // Let the SDK auto-select from available devices
      let selector = AutoDeviceSelector(wearables: wearables)
      self.deviceSelector = selector

      // Monitor device availability
      deviceMonitorTask = Task { @MainActor in
        for await device in selector.activeDeviceStream() {
          self.hasActiveDevice = device != nil
          // Glasses appeared: open the session so the capture button is live.
          if device != nil, self.deviceSession == nil {
            self.openSession(userInitiated: false)
          }
        }
      }
    } else {
      self.deviceSelector = nil
    }

    setupVideoDecoder()

    // Standby can only be (re)entered in the foreground; retry whenever the
    // app comes back, e.g. after a phone call ended it.
    activeObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      NSLog("[App] did become active")
      Task { @MainActor [weak self] in self?.enterStandbyIfPossible() }
    }
    backgroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { _ in
      NSLog("[App] did enter background, background time remaining: %.0f s",
            UIApplication.shared.backgroundTimeRemaining)
    }
    startHeartbeat()
  }

  private var activeObserver: NSObjectProtocol?
  private var backgroundObserver: NSObjectProtocol?
  private var heartbeatTask: Task<Void, Never>?

  /// Proves in the log whether the app is still running while the phone is
  /// locked. If the heartbeat stops, iOS suspended the process.
  private func startHeartbeat() {
    heartbeatTask?.cancel()
    heartbeatTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 20_000_000_000)
        guard let self else { return }
        let appState: String
        switch UIApplication.shared.applicationState {
        case .active: appState = "active"
        case .inactive: appState = "inactive"
        case .background: appState = "background"
        @unknown default: appState = "?"
        }
        NSLog("[Heartbeat] app=%@ session=%@ inputs=%@ streaming=%@ gemini=%@ standby=%@",
              appState,
              self.deviceSession.map { String(describing: $0.state) } ?? "nil",
              self.inputs.map { String(describing: $0.state) } ?? "nil",
              String(describing: self.streamingStatus),
              self.geminiSessionVM?.isGeminiActive == true ? "active" : "idle",
              self.geminiSessionVM?.isInStandby == true ? "yes" : "no")
      }
    }
  }

  /// Hands-free standby: open the mic path now so the capture button works
  /// from the lock screen. Safe to call often.
  func enterStandbyIfPossible() {
    guard streamingMode == .glasses, inputs != nil else { return }
    geminiSessionVM?.enterStandbyIfPossible()
  }

  private func setupVideoDecoder() {
    videoDecoder.setFrameCallback { [weak self] decodedFrame in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let pixelBuffer = decodedFrame.pixelBuffer
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if let cgImage = self.cpuCIContext.createCGImage(ciImage, from: rect) {
          let image = UIImage(cgImage: cgImage)
          self.geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
          if self.backgroundFrameCount <= 5 || self.backgroundFrameCount % 120 == 0 {
            NSLog("[Stream] Background frame #%d decoded and forwarded (%dx%d)",
                  self.backgroundFrameCount, width, height)
          }
        }
      }
    }
  }

  /// Store the resolution to use for the next stream. In DAT 1.0 the config is
  /// applied when the camera is added, so this only takes effect when not streaming.
  func updateResolution(_ resolution: StreamingResolution) {
    guard !isStreaming else { return }
    selectedResolution = resolution
    NSLog("[Stream] Resolution changed to %@", resolutionLabel)
  }

  private func streamConfig() -> StreamConfiguration {
    // 720x1280 (.high) rather than 360x640. At the low tier, printed text is a
    // few pixels tall before JPEG compression halves it again -- the model could
    // read a receipt's header and total but nothing smaller.
    StreamConfiguration(
      videoCodec: VideoCodec.raw,
      resolution: selectedResolution,
      frameRate: requestedFrameRate)
  }

  // MARK: - Device session (DAT 1.0)

  private func observeSession(_ session: DeviceSession) {
    sessionStateListenerToken = session.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        self?.handleSessionState(state)
      }
    }
    sessionErrorListenerToken = session.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in
        self?.handleSessionError(error)
      }
    }
  }

  private func handleSessionState(_ state: DeviceSessionState) {
    NSLog("[Stream] Device session state: %@", String(describing: state))
    switch state {
    case .started:
      if inputs == nil {
        attachInputs()
      }
      // A camera can only be added to a started session; start it now if the
      // user asked to stream and one isn't already attached.
      if wantsStream, camera == nil {
        beginStream()
      }
    case .idle, .stopped:
      camera = nil
      detachInputs()
      deviceSession = nil
      wantsStream = false
      currentVideoFrame = nil
      hasReceivedFirstFrame = false
      streamingStatus = .stopped
      scheduleSessionRetry()
    case .starting, .stopping, .paused:
      // Only a stream the user asked for is "waiting"; the quiet session kept
      // open for the capture button must not look like a starting stream, or
      // the screen auto-starts Gemini on it.
      streamingStatus = wantsStream ? .waiting : .stopped
    }
  }

  private func handleSessionError(_ error: DeviceSessionError) {
    switch error {
    case .noEligibleDevice:
      // No glasses in range or awake. While the user has not asked to stream
      // this is just the idle state, not something to alert about.
      if streamingStatus == .stopped && !wantsStream { return }
      showError("No glasses found. Make sure they are on, unfolded and connected in the Meta AI app.")
    case .insufficientSDKVersion:
      showError("The glasses no longer accept this app's Meta toolkit version. Update the meta-wearables-dat-ios package in Xcode and rebuild.")
    case .datAppOnTheGlassesUpdateRequired:
      // Not the glasses firmware: the toolkit's own "Wearables App" on the
      // glasses is missing or outdated. Meta AI installs it; the SDK knows the
      // screen, so send the user straight there.
      showError("The Meta toolkit app on the glasses is missing or outdated. Opening Meta AI to install it; keep the glasses on, charged above 10%, and Wi-Fi enabled on the phone.")
      Task {
        do {
          try await wearables?.openDATGlassesAppUpdate()
          NSLog("[Stream] openDATGlassesAppUpdate opened Meta AI")
        } catch {
          NSLog("[Stream] openDATGlassesAppUpdate failed: %@", String(describing: error))
        }
      }
    case .dwaOutOfStuRange:
      // Non-blocking compatibility warning: streaming continues.
      NSLog("[Stream] DAT compatibility warning: %@", error.description)
    default:
      showError(error.description)
    }
  }

  /// Adds a camera to the started session, wires its stream's listeners, then
  /// starts it. Video frames flow through `camera.stream.videoFramePublisher`.
  private func beginStream() {
    guard let session = deviceSession, session.state == .started else { return }
    do {
      guard let newCamera = try session.addCamera(config: streamConfig()) else {
        showError("The glasses did not provide a camera. Please try again.")
        return
      }
      camera = newCamera
      streamHasStarted = false
      // Subscribe before start() so no initial state transitions are missed.
      attachStreamListeners(to: newCamera.stream)
      newCamera.stream.start()
    } catch {
      camera = nil
      handleSessionError(error)
    }
  }

  private func attachStreamListeners(to stream: MWDATCamera.Stream) {
    // Subscribe to stream state changes using the DAT SDK listener pattern
    stateListenerToken = stream.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        self?.updateStatusFromState(state)
      }
    }

    // Subscribe to video frames from the device camera
    // This callback fires whether the app is in the foreground or background,
    // enabling continuous streaming even when the screen is locked.
    videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] videoFrame in
      Task { @MainActor [weak self] in
        guard let self else { return }

        self.fpsCount += 1
        let fpsElapsed = Date.now.timeIntervalSince(self.fpsWindowStart)
        if fpsElapsed >= 3 {
          NSLog("[Stream] delivered %.1f fps (requested %u)",
                Double(self.fpsCount) / fpsElapsed, self.requestedFrameRate)
          self.fpsCount = 0
          self.fpsWindowStart = .now
        }

        let isInBackground = UIApplication.shared.applicationState == .background

        if !isInBackground {
          self.backgroundFrameCount = 0
          self.bgDiagLogged = false
          if let image = videoFrame.makeUIImage() {
            self.currentVideoFrame = image
            if !self.hasReceivedFirstFrame {
              self.hasReceivedFirstFrame = true
            }
            self.geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
          }
        } else {
          // In background: makeUIImage() uses VideoToolbox GPU rendering which iOS suspends.
          // Instead, use our VideoDecoder (VTDecompressionSession) to decode compressed
          // frames into pixel buffers, then convert via CPU CIContext.
          self.backgroundFrameCount += 1

          let sampleBuffer = videoFrame.sampleBuffer
          let hasCompressedData = CMSampleBufferGetDataBuffer(sampleBuffer) != nil

          if hasCompressedData {
            // Compressed frame (HEVC/H.264) - decode via VTDecompressionSession
            do {
              try self.videoDecoder.decode(sampleBuffer)
            } catch {
              if self.backgroundFrameCount <= 5 || self.backgroundFrameCount % 120 == 0 {
                NSLog("[Stream] Background frame #%d decode error: %@",
                      self.backgroundFrameCount, String(describing: error))
              }
            }
          } else if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            // Raw pixel buffer - convert directly via CPU CIContext
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            if let cgImage = self.cpuCIContext.createCGImage(ciImage, from: rect) {
              let image = UIImage(cgImage: cgImage)
              self.geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
            }
            self.videoDecoder.invalidateSession()
          }
        }
      }
    }

    // Subscribe to streaming errors
    errorListenerToken = stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        // Suppress device-not-found errors when user hasn't started streaming yet
        if self.streamingStatus == .stopped {
          if case .deviceNotConnected = error { return }
          if case .deviceNotFound = error { return }
        }
        let newErrorMessage = self.formatStreamingError(error)
        if newErrorMessage != self.errorMessage {
          self.showError(newErrorMessage)
        }
      }
    }

    // Do not seed from stream.state here: a freshly created camera's stream is
    // .stopped until start(), and seeding that would flip streamingStatus to
    // .stopped mid-startup. The statePublisher above delivers the real
    // transitions (.starting -> .streaming) right after start().

    // Subscribe to photo capture events
    photoDataListenerToken = stream.photoDataPublisher.listen { [weak self] photoData in
      Task { @MainActor [weak self] in
        guard let self else { return }
        guard let uiImage = UIImage(data: photoData.data) else { return }
        // An agent-initiated capture is answering a question, not something the
        // user asked to see -- deliver it and stay out of the way.
        if let waiting = self.pendingStillContinuation {
          self.pendingStillContinuation = nil
          waiting.resume(returning: uiImage)
          return
        }
        self.capturedPhoto = uiImage
        self.showPhotoPreview = true
      }
    }
  }

  func handleStartStreaming() async {
    guard let wearables else {
      showError("The glasses SDK is not available on this device.")
      return
    }
    let permission = Permission.camera
    do {
      let status = try await wearables.checkPermissionStatus(permission)
      if status == .granted {
        await startSession()
        return
      }
      let requestStatus = try await wearables.requestPermission(permission)
      if requestStatus == .granted {
        await startSession()
        return
      }
      showError("Permission denied")
    } catch {
      showError("Permission error: \(error.description)")
    }
  }

  /// Starts streaming: opens the DeviceSession if needed, then adds the camera
  /// once the session reaches `.started`.
  func startSession() async {
    wantsStream = true
    if let session = deviceSession {
      // Session already up; just (re)start the camera if needed. Mark the
      // status now: the stream's own state arrives asynchronously, and callers
      // (the capture button) decide whether to start Gemini on isStreaming.
      streamingStatus = .waiting
      if session.state == .started, camera == nil {
        beginStream()
      }
      return
    }
    streamingStatus = .waiting
    if !openSession(userInitiated: true) {
      wantsStream = false
      streamingStatus = .stopped
    }
  }

  /// Creates and starts the DeviceSession. Errors are shown only when the user
  /// asked for it; the automatic open (for the capture button) stays quiet and
  /// retries when glasses come back.
  @discardableResult
  private func openSession(userInitiated: Bool) -> Bool {
    guard let wearables, let deviceSelector else {
      if userInitiated { showError("The glasses SDK is not available on this device.") }
      return false
    }
    guard deviceSession == nil else { return true }
    do {
      let session = try wearables.createSession(deviceSelector: deviceSelector)
      deviceSession = session
      // Subscribe before start() so no initial state transitions are missed.
      observeSession(session)
      try session.start()
      NSLog("[Stream] Device session started (%@)", userInitiated ? "user" : "auto")
      return true
    } catch {
      deviceSession = nil
      if userInitiated {
        handleSessionError(error)
      } else {
        NSLog("[Stream] Auto session open failed: %@", error.description)
        scheduleSessionRetry()
      }
      return false
    }
  }

  private func scheduleSessionRetry() {
    sessionRetryTask?.cancel()
    sessionRetryTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 5_000_000_000)
      guard !Task.isCancelled, self.deviceSession == nil, self.hasActiveDevice else { return }
      self.openSession(userInitiated: false)
    }
  }

  // MARK: - Glasses capture button

  private func attachInputs() {
    guard let session = deviceSession, session.state == .started else { return }
    do {
      guard let newInputs = try session.addInputs(
        configuration: InputsConfiguration(sources: [.captureButton])) else {
        NSLog("[Inputs] addInputs returned nil")
        return
      }
      inputs = newInputs
      inputsStateToken = newInputs.statePublisher.listen { state in
        NSLog("[Inputs] state: %@", String(describing: state))
      }
      inputsErrorToken = newInputs.errorPublisher.listen { error in
        NSLog("[Inputs] error: %@", error.description)
      }
      inputsEventsTask = Task { @MainActor [weak self] in
        for await event in newInputs.events {
          guard let self, !Task.isCancelled else { return }
          self.handleInput(event)
        }
      }
      NSLog("[Inputs] Capture button attached")
      geminiSessionVM?.enterStandbyIfPossible()
    } catch {
      NSLog("[Inputs] addInputs failed: %@", error.description)
    }
  }

  private func detachInputs() {
    if inputs != nil { NSLog("[Inputs] Detached") }
    inputsEventsTask?.cancel()
    inputsEventsTask = nil
    inputsStateToken = nil
    inputsErrorToken = nil
    inputs = nil
  }

  private func handleInput(_ event: InputEvent) {
    NSLog("[Inputs] event: %@", String(describing: event))
    guard case .capture(let press, _, _) = event else { return }
    switch press {
    case .doublePress:
      pendingSinglePress?.cancel()
      pendingSinglePress = nil
      Task { await toggleConversationFromGlasses() }
    case .shortPress:
      pendingSinglePress?.cancel()
      pendingSinglePress = Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard !Task.isCancelled, let self else { return }
        self.pendingSinglePress = nil
        await self.photoFromGlasses()
      }
    default:
      break
    }
  }

  /// Single press on the capture button: take a sharp photo, save it to the
  /// Photos library, and have Gemini describe it. Starts the conversation
  /// first if none is running.
  private func photoFromGlasses() async {
    guard streamingMode == .glasses, !singlePressInFlight else { return }
    singlePressInFlight = true
    defer { singlePressInFlight = false }

    if !isStreaming {
      NSLog("[Inputs] Single press: starting conversation first")
      await handleStartStreaming()
      await startGeminiIfNeeded(reason: "single press")
    }
    // Wait for frames to flow and Gemini to be ready (up to ~10 s).
    for _ in 0..<40 {
      if streamingStatus == .streaming, geminiSessionVM?.connectionState == .ready { break }
      try? await Task.sleep(nanoseconds: 250_000_000)
    }
    guard streamingStatus == .streaming else {
      NSLog("[Inputs] Single press: camera never started, no photo")
      return
    }
    guard let image = await captureStillForAgent() else {
      NSLog("[Inputs] Single press: photo capture failed")
      return
    }
    NSLog("[Inputs] Single press: photo %dx%d", Int(image.size.width), Int(image.size.height))
    saveToPhotos(image)
    geminiSessionVM?.describeStill(image)
  }

  /// The screen also starts Gemini when streaming begins, but only reliably in
  /// the foreground; from the lock screen the button path must do it itself.
  private func startGeminiIfNeeded(reason: String) async {
    guard let gemini = geminiSessionVM else {
      NSLog("[Inputs] %@: no Gemini view model attached", reason)
      return
    }
    guard isStreaming else {
      NSLog("[Inputs] %@: camera did not start (%@), not starting Gemini", reason, errorMessage)
      return
    }
    guard GeminiConfig.isConfigured else {
      NSLog("[Inputs] %@: Gemini API key not configured", reason)
      return
    }
    guard !gemini.isGeminiActive else { return }
    NSLog("[Inputs] %@: starting Gemini", reason)
    await gemini.startSession()
    if let reported = gemini.errorMessage, !reported.isEmpty {
      NSLog("[Inputs] %@: Gemini start reported: %@", reason, reported)
    }
  }

  private func saveToPhotos(_ image: UIImage) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        NSLog("[Photos] Not authorized to add photos (%d)", status.rawValue)
        return
      }
      PHPhotoLibrary.shared().performChanges({
        PHAssetChangeRequest.creationRequestForAsset(from: image)
      }) { ok, error in
        NSLog("[Photos] Saved: %@ %@", ok ? "yes" : "no", error?.localizedDescription ?? "")
      }
    }
  }

  /// Double press on the capture button: start the camera + Gemini, or end both.
  private func toggleConversationFromGlasses() async {
    guard streamingMode == .glasses else { return }
    if isStreaming {
      NSLog("[Inputs] Double press: ending conversation")
      geminiSessionVM?.stopSession()
      await stopSession()
    } else {
      NSLog("[Inputs] Double press: starting conversation")
      await handleStartStreaming()
      await startGeminiIfNeeded(reason: "double press")
    }
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  /// Stops the camera stream. The device session itself stays open so the
  /// capture button keeps working; it ends on its own when the glasses go away.
  func stopSession() async {
    if streamingMode == .iPhone {
      stopIPhoneSession()
      return
    }
    wantsStream = false
    if let camera {
      camera.stop()
    }
    camera = nil
    stateListenerToken = nil
    videoFrameListenerToken = nil
    errorListenerToken = nil
    photoDataListenerToken = nil
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    streamingStatus = .stopped
  }

  // MARK: - iPhone Camera Mode

  func handleStartIPhone() async {
    let granted = await IPhoneCameraManager.requestPermission()
    if granted {
      startIPhoneSession()
    } else {
      showError("Camera permission denied. Please grant access in Settings.")
    }
  }

  private func startIPhoneSession() {
    streamingMode = .iPhone
    let camera = IPhoneCameraManager()
    camera.onFrameCaptured = { [weak self] image in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.currentVideoFrame = image
        if !self.hasReceivedFirstFrame {
          self.hasReceivedFirstFrame = true
        }
        self.geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
      }
    }
    camera.start()
    iPhoneCameraManager = camera
    streamingStatus = .streaming
    NSLog("[Stream] iPhone camera mode started")
  }

  private func stopIPhoneSession() {
    iPhoneCameraManager?.stop()
    iPhoneCameraManager = nil
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    streamingStatus = .stopped
    streamingMode = .glasses
    NSLog("[Stream] iPhone camera mode stopped")
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  func capturePhoto() {
    _ = camera?.stream.capturePhoto(format: .jpeg)
  }

  private var pendingStillContinuation: CheckedContinuation<UIImage?, Never>?

  /// Full-resolution still for the model to read, rather than a downscaled
  /// stream frame. Returns nil if the capture fails or the glasses never answer;
  /// a hung continuation would leave a tool call outstanding forever.
  func captureStillForAgent(timeout: TimeInterval = 6) async -> UIImage? {
    // Phone mode: the converted frame is already 1920x1080 off the same sensor
    // the preview shows, so it is the sharp still -- no photo round-trip needed.
    if streamingMode == .iPhone { return currentVideoFrame }
    guard let stream = camera?.stream else { return nil }
    if pendingStillContinuation != nil { return nil }

    let image = await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
      pendingStillContinuation = cont
      guard stream.capturePhoto(format: .jpeg) else {
        pendingStillContinuation = nil
        cont.resume(returning: nil)
        return
      }
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        if let stale = self.pendingStillContinuation {
          self.pendingStillContinuation = nil
          stale.resume(returning: nil)
        }
      }
    }
    return image
  }

  func dismissPhotoPreview() {
    showPhotoPreview = false
    capturedPhoto = nil
  }

  private func updateStatusFromState(_ state: StreamState) {
    NSLog("[Stream] Stream state: %@", String(describing: state))
    switch state {
    case .stopped:
      guard streamHasStarted || !wantsStream else {
        NSLog("[Stream] Ignoring .stopped before the stream started")
        return
      }
      currentVideoFrame = nil
      streamingStatus = .stopped
    case .waitingForDevice, .starting, .stopping, .paused:
      streamHasStarted = true
      streamingStatus = .waiting
    case .streaming:
      streamHasStarted = true
      streamingStatus = .streaming
    }
  }

  private func formatStreamingError(_ error: StreamError) -> String {
    switch error {
    case .internalError:
      return "An internal error occurred. Please try again."
    case .deviceNotFound:
      return "Device not found. Please ensure your device is connected."
    case .deviceNotConnected:
      return "Device not connected. Please check your connection and try again."
    case .timeout:
      return "The operation timed out. Please try again."
    case .videoStreamingError:
      return "Video streaming failed. Please try again."
    case .audioStreamingError:
      return "Audio streaming failed. Please try again."
    case .permissionDenied:
      return "Camera permission denied. Please grant permission in Settings."
    case .hingesClosed:
      return "The hinges on the glasses were closed. Please open the hinges and try again."
    case .thermalHot:
      return "The glasses are too hot to stream. Let them cool down and try again."
    case .batteryLow:
      return "The glasses battery is too low to stream. Charge them and try again."
    case .peakPowerLimit:
      return "The glasses paused streaming to protect their battery. Please try again shortly."
    case .photoCaptureFailed:
      return "Photo capture failed. Please try again."
    @unknown default:
      return "An unknown streaming error occurred."
    }
  }
}
