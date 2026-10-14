# VisionClaw (Gemini direct) build notes

Branch `gemini-direct-dat1`, based on upstream commit `1db325a` (2026-07-30, the last
commit before the LiveKit migration). Prepared 2026-10-14 on the MacBook.

## What changed versus `1db325a` and why

| File | Change | Reason |
|---|---|---|
| `CameraAccess.xcodeproj/project.pbxproj` | Meta toolkit pin 0.4.0 -> 1.0.1, deployment target 17.0 -> 17.2 | The upstream author's own commit 9125d68 says "0.4 can't stream from 0.9 devices". Meta's version table maps current glasses firmware (V128) to SDK 1.0.0, and the SDK reports `insufficientSDKVersion` for apps on an SDK the glasses no longer accept. 1.0.x requires iOS 17.2. |
| `ViewModels/StreamSessionViewModel.swift` | Ported from the 0.4 `StreamSession` API to the 1.0 `DeviceSession` + `Camera` + `Stream` model | Same approach as upstream commit 9125d68, minus the LiveKit bits. Public surface unchanged, so views and the Gemini bridge are untouched. |
| `Info.plist` | Merged the two `CFBundleURLTypes` blocks into one | A duplicate key is invalid; the second copy could drop the `cameraaccess://` scheme that Meta AI calls back to after registration. Same fix as upstream 6d02f6a. |
| `CameraAccess.entitlements` | Added keychain-access-groups (the Hotspot and Wi-Fi-info entitlements were tried and removed: a free Personal Team cannot sign them) | Upstream 53bd4d8: without the keychain group the SDK cannot persist registration and re-opens Meta AI on every connect. The Wi-Fi entitlements are for the glasses video link. |
| `OpenClaw/ToolCallModels.swift`, `Gemini/GeminiConfig.swift` | `execute` tool and the agent-centric default prompt only when an action agent is configured | Otherwise Gemini is told to delegate everything to a tool that always fails. Standalone mode keeps `look_closely` and `create_reminder`. |

Status 2026-10-14 (later): Xcode 27 installed. The app compiles cleanly for the iOS Simulator
with toolkit 1.0.1 (one fix was needed after the first build: `StreamState.waitingForDevice`).
Bundle identifier set to `com.chip.VisionClaw` (change it under Signing & Capabilities if you
prefer another). Team set to 55G296C9TL (Personal Team, free), development certificate created. The device
build is blocked only on iOS Developer Mode being off on the iPhone, which also blocks
registering the phone with the team.

## Steps on this Mac

1. Install Xcode from the Mac App Store (16 or newer), open it once, accept the licence, then:

   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   ```

2. Open `samples/CameraAccess/CameraAccess.xcodeproj`. Xcode resolves the Meta package
   (`meta-wearables-dat-ios` 1.0.1) on first open.
3. Xcode > Settings > Accounts: add your Apple ID. Then target **CameraAccess** >
   **Signing & Capabilities**: pick your Team (the bundle identifier is already
   `com.chip.VisionClaw`). If a free Apple ID refuses the
   Hotspot Configuration or Access Wi-Fi Information capabilities, remove those two keys
   from `CameraAccess.entitlements` and try again (keep keychain-access-groups).
4. Gemini key: either paste it into `CameraAccess/Secrets.swift` (already created from the
   example, gitignored) or leave the file alone and enter the key in the app's Settings
   screen after the first launch. The in-app setting overrides the file.
5. Plug in the iPhone, select it as the run destination, Cmd+R. On the phone, trust the
   developer profile under Settings > General > VPN & Device Management.
6. Test **Phone mode** first (iPhone camera, no glasses). Then **Glasses mode**: Start
   Streaming, approve the link in Meta AI, tap the AI button, talk.

## If the first build fails

The port was written against the 1.0.1 Swift interfaces in the package, so errors should be
small. Likely spots:

- `StreamSessionViewModel.swift`: typed throws (`throws(DeviceSessionError)`) need the
  Swift 6 compiler that ships with Xcode 16+.
- `MockDeviceKit` files are excluded by `#if canImport(MWDATMockDevice)` because that
  product is not linked; if Xcode ever links it, those files use APIs removed in 0.8.0.
- `CameraAccessTests` use `MockRaybanMeta` (removed in 0.8.0). The test target is not needed
  to run the app.

## Working state (2026-10-14 evening)

Phone mode and glasses mode both work on the iPhone 15 Pro Max with the Meta Adventurer LISA
Edition glasses, toolkit 1.0.1, free Personal Team signing (no Wi-Fi entitlements).

Lesson from the first glasses attempt: `DeviceSessionError.datAppOnTheGlassesUpdateRequired`
does not mean the glasses firmware is old. It means the toolkit's own on-glasses component
(the "DAT Wearables App") is missing or older than the SDK requires. Meta AI installs it when a
developer-mode app links; re-linking with the glasses on, charged above 10% and phone Wi-Fi on
fixed it. The app now opens Meta AI's app-connections screen on that error.

Reminder: a Personal Team build stops launching 7 days after install. Rebuild and reinstall
from Xcode (Cmd+R with the phone connected) or ask Claude to run the same build and install.

## Still unconfirmed (historical)

Whether the Meta Adventurer LISA Edition glasses are supported by the toolkit at all. Phase 0
of the handoff brief (firmware >= V128, Meta AI app >= V290, Developer Mode on) decides that
on the phone.
