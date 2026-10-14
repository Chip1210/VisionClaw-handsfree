# VisionClaw Hands-Free: Gemini on Meta glasses, started from the glasses

Talk to Google Gemini through Meta smart glasses without touching your phone.
Double-press the capture button, hear two beeps, and talk. Gemini sees what you
see, answers through the glasses' speakers, and works with the phone locked in
your pocket. A single press takes a sharp photo, saves it to your iPhone's Photos,
and has Gemini describe it.

This is a personal fork of [Intent-Lab/VisionClaw](https://github.com/Intent-Lab/VisionClaw),
taken from the last commit that talked to Gemini directly (`1db325a`, 2026-07-30), ported
to Meta's current toolkit and rebuilt around hands-free use. No cloud gateway, no accounts,
no server: the phone connects straight to the Gemini Live API with your own key.

Tested on 2026-10-15 with Meta Adventurer LISA Edition glasses (firmware V128),
an iPhone 15 Pro Max, the Meta AI app V290+, Xcode 27, and a free Apple ID.

## What it does

| On the glasses | What happens |
|---|---|
| Double-press the capture button | Starts a Gemini conversation. Two rising beeps in the glasses mean it is listening. Double-press again to end. Works with the phone locked. |
| Single press | Takes a full-resolution photo, saves it to the iPhone Photos library, and Gemini describes it aloud, reading any text. Starts a conversation first if none is running. |
| Talk | Gemini hears you through the glasses' microphones and answers through the glasses' speakers, about 1 second after you stop talking. It also sees a frame per second from the camera. |

Gemini runs with the camera, a "look closely" tool that takes a sharp still when detail
matters, and on-device reminders and calendar tools. The optional action agent of the
original project (messages, lists, web search through OpenClaw or a cloud gateway) is
still in the code but off unless you configure it.

## How it works

```
Meta glasses  --Bluetooth--> iPhone app (this repo) --WebSocket--> Gemini Live API
  camera, mic, speaker          Meta Wearables Device Access Toolkit 1.0.1
  capture button                                  gemini-3.8-live or
                                                  gemini-2.5-flash native audio
```

Meta does not let anyone replace Meta AI on the glasses. "Hey Meta" still goes to Meta AI.
What Meta's toolkit allows is a phone app that takes over the glasses' camera, microphone,
speaker and buttons for the length of a session. That is what this app does.

The hard part was starting a session from a locked phone. iOS refuses to let an app begin
audio capture from the background, so this app keeps a standby microphone path open while
it is idle (orange dot on the phone, audio discarded) and a double press only switches it to
live. Details and every dead end are in
[samples/CameraAccess/BUILD-NOTES.md](samples/CameraAccess/BUILD-NOTES.md).

## Requirements

- Meta glasses supported by Meta's toolkit, on firmware V128 or newer, paired with the
  Meta AI app V290 or newer. Check Meta's
  [version table](https://wearables.developer.meta.com/docs/develop/dat/version-dependencies/).
- An iPhone on iOS 17.2 or newer.
- A Mac with Xcode 16 or newer. A free Apple ID works, with limits noted below.
- A Gemini API key from [Google AI Studio](https://aistudio.google.com/apikey).

## Setup

### 1. Glasses: enable Developer Mode

In the Meta AI app: Settings > App Info > tap the version number five times > turn on
Developer Mode. Confirm Settings > App connections now shows "Developer mode apps".

### 2. Build the app

```bash
git clone https://github.com/Chip1210/VisionClaw-handsfree.git
cd VisionClaw-handsfree/samples/CameraAccess
cp CameraAccess/Secrets.swift.example CameraAccess/Secrets.swift
open CameraAccess.xcodeproj
```

In Xcode, select the CameraAccess target > Signing & Capabilities: pick your Team and set
your own bundle identifier. Xcode fetches Meta's toolkit package on first open. Plug in the
iPhone, select it as the destination, press Run. On the phone, trust the developer profile
under Settings > General > VPN & Device Management.

Your Gemini key goes either into `Secrets.swift` (ignored by git, never committed) or into
the app's own Settings screen after first launch. The in-app setting wins.

### 3. First link

1. Test Phone mode first: capture source = iPhone camera, Start, talk. No glasses needed.
2. Switch the capture source to Glasses, put the glasses on, charge them above 10%, keep the
   phone's Wi-Fi on, tap Start Streaming, approve the link in Meta AI when it opens.
3. If the app says the toolkit app on the glasses is missing, Meta AI installs it during
   the link. Re-link with the glasses on your face and Meta AI in the foreground for ten
   seconds. This is a known rough edge of Meta's toolkit, not a firmware problem.

### 4. Hands-free

Open the app once so the orange microphone dot appears, then lock the phone and put it
away. From now on the capture button drives everything. The app has to stay running: do not
swipe it away. If you do, open it once more.

## Known limits

- **Free Apple ID**: the install stops launching seven days after you build it. Rebuild
  from Xcode. The paid Developer Program removes this and allows the Wi-Fi entitlements a
  personal team cannot sign.
- **Audio quality**: Meta routes third-party audio over the Bluetooth hands-free profile,
  so Gemini's voice sounds like a phone call in the glasses. Platform limit.
- **The orange dot**: standby keeps the microphone path open while the app runs. Audio is
  discarded until you double-press. Turn it off under Settings > Hands-free if you prefer
  starting from the phone screen.
- **Single press is taken over**: while the app runs, the glasses' own single-press photo
  no longer fires. Quit the app to get it back.
- **"Hey Meta, start VisionClaw"**: the code for Meta's voice launch is in place, but Meta
  AI only routes the phrase for apps registered in the Wearables Developer Center with the
  Voice invocation permission approved. Developer Mode alone does not.
- Meta's input, photo and voice-invocation features are marked experimental by Meta.

## What changed from the original project

Compared with upstream commit `1db325a` (the version this fork is based on). Upstream's
current `main` went a different way (LiveKit cloud agent, access-code gate); this fork does
not include any of that.

| Area | Change | Why |
|---|---|---|
| Meta toolkit | 0.4.0 to 1.0.1; iOS 17.2 minimum | 0.4 cannot stream from current glasses firmware |
| Streaming | `StreamSessionViewModel` ported to the toolkit's session, camera and stream model | API changed between 0.4 and 1.0 |
| Capture button | Double press starts and ends Gemini; single press is photo-to-Photos plus a Gemini description (toolkit `MWDATInputs`) | Hands-free use |
| Lock-screen start | Standby microphone kept open while idle, with a Settings toggle | iOS refuses to start audio capture from the background |
| Audio routing | Prefers the glasses' Bluetooth hands-free input; mic starts before the Gemini handshake; speech during connection is buffered; two beeps when ready | Replies played on the phone; app got suspended mid-handshake; first words were lost |
| Gemini model | `gemini-live-2.5-flash-preview` replaced by `gemini-3.8-live` | Google retired the old model |
| Errors | Shows Google's close reason; explains the toolkit's "glasses app update required" and opens Meta AI | Generic failures hid the real cause |
| Tools and prompt | The `execute` action tool and its prompt only when an action agent is configured | Otherwise Gemini delegated everything to a tool that always failed |
| Voice launch | Subscribes to Meta's voice invocations (`VoiceInvocationsStream`) | Ready for "Hey Meta, start VisionClaw" once Meta routes it |
| Robustness | Per-attempt connect timeout; websocket callbacks scoped to their task; stale stream state ignored; heartbeat logging | Each of these ended the second conversation after the first |
| Project | Duplicate URL-types block merged; keychain entitlement; `bluetooth-central` background mode; Team ID left blank | Registration persistence and background links |

The original README is kept at [docs/UPSTREAM-README.md](docs/UPSTREAM-README.md). The
Android sample, the Python agent and the gateway directories are upstream's and untouched.

## Credits

- [Intent-Lab/VisionClaw](https://github.com/Intent-Lab/VisionClaw) by Xiaoan Liu, the
  project this is forked from.
- [Meta Wearables Device Access Toolkit](https://github.com/facebook/meta-wearables-dat-ios).
- Google Gemini Live API.
- The port and hands-free work were done with Claude Code.

License: see [LICENSE](LICENSE), inherited from the upstream project.
