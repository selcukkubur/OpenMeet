# Camera-Based Meeting Detection

**Date:** 2026-04-05
**Status:** Draft

## Problem

OpenOats detects meetings by monitoring microphone activation status via CoreAudio (`kAudioDevicePropertyDeviceIsRunningSomewhere`). This triggers false positives from dictation apps (Almond, SuperWhisper), voice messages (WhatsApp), and other non-meeting mic usage. The current code emits `.detected(app)` even when no meeting app is found (`app == nil`), so any mic activation fires a detection notification.

## Solution

Add camera-based detection as the strongest meeting signal using CoreMediaIO property listeners. Restructure `MeetingDetector` to use priority-based multi-signal evaluation:

| Priority | Condition | Debounce | Rationale |
|----------|-----------|----------|-----------|
| 0 (strongest) | Camera ON | None (instant) | Nobody turns on camera outside meetings |
| 1 | Mic ON + meeting app running | 5s | Current behavior, but now requires app presence |
| 2 | Mic ON alone | — | **No detection** (this is the fix) |

The notification flow still prompts the user before starting transcription, but notification copy adapts to the detection trigger (see NotificationService section).

## Architecture

### New: CameraSignalSource

**File:** `Sources/OpenOats/Meeting/CameraActivityMonitor.swift`

**Protocol:** `CameraSignalSource` — mirrors existing `AudioSignalSource`:
```swift
protocol CameraSignalSource: Sendable {
    var signals: AsyncStream<Bool> { get }
}
```

**Implementation:** `CoreMediaIOSignalSource`

Uses CoreMediaIO C APIs for event-driven camera status monitoring:
1. **Device enumeration via CoreMediaIO** (not AVCaptureDevice): query `kCMIOHardwarePropertyDevices` on `kCMIOObjectSystemObject` to get all CMIO device IDs, then filter to video devices by checking `kCMIODevicePropertyStreams` with `kCMIODevicePropertyScopeInput`. This keeps everything in the CMIO world — no AVFoundation/CMIO ID mapping needed.
2. **Initial state read**: on init, read `kCMIODevicePropertyDeviceIsRunningSomewhere` for all discovered devices and emit the initial aggregate state immediately. This ensures `evaluateImmediate()` works if a camera is already active at app launch.
3. **System-level listener** on `kCMIOHardwarePropertyDevices` for hot-plug (cameras added/removed). On callback: diff against tracked devices, install listeners on new devices, remove listeners on removed devices.
4. **Per-device listener** on `kCMIODevicePropertyDeviceIsRunningSomewhere` for running state changes.
5. **On callback**: check all tracked devices, deduplicate state changes via `lastEmittedValue`, yield to `AsyncStream`.
6. **Teardown in `deinit`**: remove all per-device listeners and the system-level listener. Same lifecycle pattern as `CoreAudioSignalSource`.

Same architectural pattern as existing `CoreAudioSignalSource`: `DispatchQueue` for thread safety, `Unmanaged` pointers for C callback bridging, dedup via `lastEmittedValue`.

**No new entitlements required.** `kCMIODevicePropertyDeviceIsRunningSomewhere` is a status read ("is the camera running in any process?"), not a capture. Confirmed against SDK headers. App is not sandboxed.

### Modified: MeetingDetector

**File:** `Sources/OpenOats/Meeting/MeetingDetector.swift`

Changes to the existing actor:

1. **New init parameter:** `cameraSource: (any CameraSignalSource)?` — defaults to `CoreMediaIOSignalSource()`
2. **New state:** `isCameraActive: Bool`, `isMicActive: Bool`, `detectionTrigger: DetectionTrigger?`
3. **Separate camera monitoring task** in `start()` — runs independently from the mic monitoring task so camera signals aren't blocked behind a 5s mic debounce sleep
4. **Priority evaluation replaces `handleMicSignal`:**
   - Camera ON → immediate `.detected(app)` (scan for app name, but detection fires regardless)
   - Mic ON → debounce 5s, then scan for meeting app. If app found → `.detected(app)`. If no app → no detection.
   - Mic OFF → if trigger was `.micAndApp`, emit `.ended`
   - Camera OFF → if trigger was `.camera`, emit `.ended`
5. **Overlap handling:** If already active, new signals don't re-emit `.detected`. The `detectionTrigger` tracks the *strongest* active signal. End condition: meeting ends only when *all* active signals are off. Specifically:
   - Camera ON + mic+app active → trigger is `.camera`. Camera turns off → check if mic+app still active. If yes, downgrade trigger to `.micAndApp`, meeting continues. If no, emit `.ended`.
   - Mic+app active → trigger is `.micAndApp`. Camera turns on → upgrade trigger to `.camera`. Mic turns off → meeting continues (camera still on).
   - Both off → emit `.ended`.
6. **Debounce cancellation on camera events:** When camera turns ON while a mic debounce is in-flight, the debounce is cancelled (the camera signal supersedes it). When camera turns OFF, any pending mic debounce is left alone (it may still produce a valid `.micAndApp` detection).
7. **Camera-off hysteresis:** Brief camera toggles (e.g. device handoff, virtual camera restart) should not immediately end a session. Add a 3-second grace period after camera turns OFF before evaluating end conditions. If camera turns back ON within the grace period, the session continues uninterrupted.
8. **`queryCurrentState()` update:** Now returns camera state in addition to mic state, reading the actual hardware status from both signal sources (not just actor memory). Used by `evaluateImmediate()` for mid-meeting app launch detection. Requires adding a `var isActive: Bool { get }` property to both `AudioSignalSource` and `CameraSignalSource` protocols (synchronous read of current hardware state, separate from the async stream).

```swift
enum DetectionTrigger: Sendable {
    case camera
    case micAndApp
}
```

### Modified: DetectionSignal

**File:** `Sources/OpenOats/Domain/MeetingTypes.swift`

Add new case:
```swift
case cameraActivated
```

This flows through `DetectionContext` → `MeetingMetadata` for logging/UI purposes.

### Modified: MeetingDetectionController

**File:** `Sources/OpenOats/App/MeetingDetectionController.swift`

Changes:

1. **Frozen notification context:** When `.detected` fires, capture a `DetectionSnapshot` (trigger type, detected app, timestamp) and store it on the controller. When the user accepts, build `MeetingMetadata` from the snapshot — not from mutable detector state, which may have changed between notification post and user action.

2. **Stale notification cancellation:** When `.ended` fires from the detector, if there's a pending (unanswered) notification, cancel it via `notificationService?.cancelPending()`. This prevents accepting a stale notification after the meeting signal has gone away.

3. **Camera-only dismiss/ignore:** Replace `"__camera__"` magic string. Instead, change `dismissedEvents` from `Set<String>` to `Set<DismissKey>` where:
   ```swift
   enum DismissKey: Hashable {
       case app(bundleID: String)
       case cameraOnly
   }
   ```
   - `handleDetectionNotAMeeting()`: when no app detected, insert `.cameraOnly`. When app detected, insert `.app(bundleID:)`.
   - `handleIgnoreApp()`: camera-only detections don't offer "Ignore This App" (there's no app to ignore). The notification actions adapt based on whether an app was identified.

4. **`evaluateImmediate()` update:** Now checks both camera and mic+app state via the updated `queryCurrentState()`. If camera is active, triggers detection immediately.

5. **Dependency injection:** `setup(settings:)` gains optional parameters for injecting `MeetingDetector` and `NotificationService` (default to production instances). This enables controller-level tests without hardware dependencies.

### Modified: NotificationService

**File:** `Sources/OpenOats/Meeting/NotificationService.swift`

Update notification copy and actions based on detection trigger:

- **Camera-triggered (with app):** "Meeting detected" / subtitle: app name / actions: "Start Recording", "Not a Meeting", "Ignore This App", "Dismiss"
- **Camera-triggered (no app):** "Meeting detected" / subtitle: "Camera is active" / actions: "Start Recording", "Not a Meeting", "Dismiss" (no "Ignore This App" — no app to ignore)
- **Mic+app triggered:** "Meeting detected" / subtitle: app name / actions: same as current (unchanged)

The `postMeetingDetected` method gains a `trigger: DetectionTrigger` parameter and optional `appName: String?` to determine which copy/actions to show.

**Notification categories:** Register two UNNotificationCategory instances instead of one:
- `meetingDetectedWithApp` — includes "Start Recording", "Not a Meeting", "Ignore This App", "Dismiss"
- `meetingDetectedNoApp` — includes "Start Recording", "Not a Meeting", "Dismiss" (no "Ignore This App")

Select category based on whether an app was identified in the detection.

### Modified: AppCoordinator

**File:** `Sources/OpenOats/App/AppCoordinator.swift`

In `startDetectionEventLoop()`, lines 240-246: currently only starts silence/exit monitoring when signal is `.appLaunched`. Expand to also handle `.cameraActivated`:
- For `.cameraActivated`: start silence monitoring (same as app-launched)
- App exit monitoring for camera-triggered sessions: do NOT auto-stop when the detected app exits if camera is still on. The `.meetingAppExited` handler must check the detector's current trigger state — if camera is still the active trigger, ignore the app exit event. Only auto-stop if no other signals are active. This aligns with the "end only when all active signals are off" rule.

Similarly in the `.meetingAppExited` handler (lines 247-253): guard against stopping when camera signal is still active.

### Modified: SettingsView & SettingsStore

**File:** `Sources/OpenOats/Views/SettingsView.swift`, `Sources/OpenOats/Settings/SettingsStore.swift`

Update the detection description text (line 98) and explanation sheet (line 123) to mention camera monitoring alongside microphone monitoring:
- Line 98: "When enabled, OpenOats monitors camera and microphone activation to detect when a meeting starts."
- Line 123: Add a camera label alongside the existing mic label.

**Existing user consent:** Add a `hasShownCameraDetectExplanation` flag (defaults to `false`). On app launch, if `meetingAutoDetectEnabled` is `true` and `hasShownCameraDetectExplanation` is `false`, show an updated explanation sheet that mentions camera monitoring. This ensures existing users who already enabled auto-detect get informed about the new camera signal before it activates.

## Tests

### New: MockCameraSignalSource

Same pattern as existing `MockAudioSignalSource` — controllable `AsyncStream` for tests.

### MeetingDetector tests:

- Camera ON → instant `.detected` (no debounce wait)
- Mic ON alone → no detection emitted
- Mic ON + meeting app → `.detected` after 5s debounce
- Camera ON then OFF → `.ended` (after 3s hysteresis)
- Camera ON, then mic+app → no duplicate `.detected`
- Camera OFF while mic+app still active → trigger downgrades, meeting continues
- Mic OFF while camera still active → meeting continues
- Both OFF → `.ended`
- Camera ON during pending mic debounce → debounce cancelled, camera detection fires
- Brief camera toggle (OFF then ON within 3s) → no `.ended` emitted
- `queryCurrentState()` reflects actual hardware state

### MeetingDetectionController tests:

- Frozen snapshot: accepted metadata matches state at detection time, not accept time
- `.ended` cancels pending notification
- Camera-only dismiss inserts `.cameraOnly` key
- Camera-only detection does not offer "Ignore This App" action
- `evaluateImmediate()` detects active camera at app launch

### AppCoordinator tests:

- `.cameraActivated` signal starts silence monitoring
- `.cameraActivated` with app starts app exit monitoring
- `.cameraActivated` without app skips app exit monitoring
- Auto-stop on camera-off vs app-exit
- App exit while camera still active → session continues (no auto-stop)

### Updated existing tests:

- Tests that expected mic-only to trigger detection now need a meeting app running, or need to be updated to verify no detection occurs.

## What doesn't change

- `CoreAudioSignalSource` — minor change: add `isActive` property to protocol conformance
- `LiveSessionController` — no changes
- `AppContainer` — no changes (detector is created inside controller)
- Known meeting apps list — kept as-is
- Settings storage — one new flag: `hasShownCameraDetectExplanation`
- Session storage / JSONL format — unchanged
- Build scripts, CI — unchanged (CoreMediaIO is a system framework, no new dependencies)
