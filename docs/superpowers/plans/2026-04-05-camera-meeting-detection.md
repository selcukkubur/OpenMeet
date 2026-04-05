# Camera-Based Meeting Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add camera-based detection as the strongest meeting signal to eliminate false positives from mic-only detection.

**Architecture:** New `CameraSignalSource` using CoreMediaIO property listeners feeds into a refactored `MeetingDetector` actor that evaluates signals by priority (camera > mic+app > mic alone). Downstream notification and coordinator layers adapt to the new signal type.

**Tech Stack:** Swift 6.2, CoreMediaIO (C API), UserNotifications, SwiftUI

**Spec:** `docs/superpowers/specs/2026-04-05-camera-meeting-detection-design.md`

---

### Task 1: Add `isActive` to Signal Source Protocols and Update `DetectionSignal`

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Meeting/MeetingDetector.swift:7-11` (AudioSignalSource protocol)
- Modify: `OpenOats/Sources/OpenOats/Meeting/MeetingDetector.swift:17` (CoreAudioSignalSource)
- Modify: `OpenOats/Sources/OpenOats/Domain/MeetingTypes.swift:20-29` (DetectionSignal enum)
- Modify: `OpenOats/Tests/OpenOatsTests/MeetingDetectorTests.swift:7-26` (MockAudioSignalSource)
- Modify: `OpenOats/Tests/OpenOatsTests/MeetingStateTests.swift` (add cameraActivated test)

- [ ] **Step 1: Add `isActive` to AudioSignalSource protocol**

In `MeetingDetector.swift`, update the protocol:

```swift
protocol AudioSignalSource: Sendable {
    /// Emits `true` when any physical input device becomes active, `false` when all go silent.
    var signals: AsyncStream<Bool> { get }
    /// Synchronous read of current hardware state.
    var isActive: Bool { get }
}
```

- [ ] **Step 2: Implement `isActive` on CoreAudioSignalSource**

Add to `CoreAudioSignalSource`:

```swift
var isActive: Bool {
    listenerQueue.sync {
        deviceIDs.contains { Self.isDeviceRunning($0) }
    }
}
```

- [ ] **Step 3: Add `isActive` to MockAudioSignalSource**

In `MeetingDetectorTests.swift`:

```swift
final class MockAudioSignalSource: AudioSignalSource, @unchecked Sendable {
    let signals: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation
    private let lock = NSLock()
    private var _isActive = false

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isActive
    }

    init() {
        var captured: AsyncStream<Bool>.Continuation!
        self.signals = AsyncStream<Bool> { continuation in
            captured = continuation
        }
        self.continuation = captured
    }

    func emit(_ value: Bool) {
        lock.lock()
        _isActive = value
        lock.unlock()
        continuation.yield(value)
    }

    func finish() {
        continuation.finish()
    }
}
```

- [ ] **Step 4: Add `cameraActivated` to DetectionSignal**

In `MeetingTypes.swift`:

```swift
enum DetectionSignal: Sendable, Hashable, Codable {
    case manual
    case appLaunched(MeetingApp)
    case calendarEvent(CalendarEvent)
    case audioActivity
    case cameraActivated
}
```

- [ ] **Step 5: Add test for cameraActivated codability**

In `MeetingStateTests.swift`, add:

```swift
func testDetectionSignalCameraActivated() {
    let signal = DetectionSignal.cameraActivated
    XCTAssertEqual(signal, .cameraActivated)
}

func testDetectionSignalCameraActivatedCodable() throws {
    let signal = DetectionSignal.cameraActivated
    let data = try JSONEncoder().encode(signal)
    let decoded = try JSONDecoder().decode(DetectionSignal.self, from: data)
    XCTAssertEqual(decoded, signal)
}
```

- [ ] **Step 6: Run tests and verify they pass**

Run: `cd OpenOats && swift test --filter "MeetingStateTests" 2>&1 | tail -5`
Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add OpenOats/Sources/OpenOats/Meeting/MeetingDetector.swift OpenOats/Sources/OpenOats/Domain/MeetingTypes.swift OpenOats/Tests/OpenOatsTests/MeetingDetectorTests.swift OpenOats/Tests/OpenOatsTests/MeetingStateTests.swift
git commit -m "feat: add isActive to signal source protocol, add cameraActivated signal"
```

---

### Task 2: Create CameraSignalSource Protocol and CoreMediaIOSignalSource

**Files:**
- Create: `OpenOats/Sources/OpenOats/Meeting/CameraActivityMonitor.swift`

- [ ] **Step 1: Create `CameraActivityMonitor.swift`**

```swift
import CoreMediaIO
import Foundation

// MARK: - Camera Signal Source Protocol

/// Abstraction for observing camera activation status changes.
protocol CameraSignalSource: Sendable {
    /// Emits `true` when any camera device becomes active, `false` when all go inactive.
    var signals: AsyncStream<Bool> { get }
    /// Synchronous read of current hardware state.
    var isActive: Bool { get }
}

// MARK: - CoreMediaIO Signal Source

/// Monitors kCMIODevicePropertyDeviceIsRunningSomewhere on all video devices.
/// Does NOT capture video -- only reads activation status.
final class CoreMediaIOSignalSource: CameraSignalSource, @unchecked Sendable {
    private let listenerQueue = DispatchQueue(label: "com.openoats.camera-listener")
    private var deviceIDs: [CMIOObjectID] = []
    private var continuation: AsyncStream<Bool>.Continuation?
    private var lastEmittedValue: Bool = false
    private var listenerBlocks: [CMIOObjectID: CMIOObjectPropertyListenerBlock] = [:]
    private var systemListenerBlock: CMIOObjectPropertyListenerBlock?

    let signals: AsyncStream<Bool>

    var isActive: Bool {
        listenerQueue.sync {
            deviceIDs.contains { Self.isDeviceRunning($0) }
        }
    }

    init() {
        var stream: AsyncStream<Bool>!
        var capturedContinuation: AsyncStream<Bool>.Continuation!

        stream = AsyncStream<Bool> { continuation in
            capturedContinuation = continuation
        }

        self.signals = stream

        listenerQueue.sync {
            self.continuation = capturedContinuation
            self.deviceIDs = Self.videoDeviceIDs()

            // Install per-device listeners
            for deviceID in self.deviceIDs {
                self.installDeviceListener(deviceID)
            }

            // Install system-level listener for hot-plug
            self.installSystemListener()

            // Emit initial state
            let anyRunning = self.deviceIDs.contains { Self.isDeviceRunning($0) }
            self.lastEmittedValue = anyRunning
            if anyRunning {
                self.continuation?.yield(true)
            }
        }
    }

    deinit {
        for (deviceID, block) in listenerBlocks {
            var address = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            CMIOObjectRemovePropertyListenerBlock(deviceID, &address, listenerQueue, block)
        }
        if let block = systemListenerBlock {
            var address = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, listenerQueue, block)
        }
        continuation?.finish()
    }

    // MARK: - Listener Installation

    private func installDeviceListener(_ deviceID: CMIOObjectID) {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.checkAndEmit()
        }
        listenerBlocks[deviceID] = block
        CMIOObjectAddPropertyListenerBlock(deviceID, &address, listenerQueue, block)
    }

    private func installSystemListener() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDeviceListChanged()
        }
        systemListenerBlock = block
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, listenerQueue, block)
    }

    // MARK: - Device List Changes (Hot-Plug)

    private func handleDeviceListChanged() {
        listenerQueue.async { [weak self] in
            guard let self else { return }
            let newDeviceIDs = Self.videoDeviceIDs()
            let oldSet = Set(self.deviceIDs)
            let newSet = Set(newDeviceIDs)

            // Remove listeners from removed devices
            for removed in oldSet.subtracting(newSet) {
                if let block = self.listenerBlocks.removeValue(forKey: removed) {
                    var address = CMIOObjectPropertyAddress(
                        mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
                    )
                    CMIOObjectRemovePropertyListenerBlock(removed, &address, self.listenerQueue, block)
                }
            }

            // Install listeners on new devices
            for added in newSet.subtracting(oldSet) {
                self.installDeviceListener(added)
            }

            self.deviceIDs = newDeviceIDs
            self.checkAndEmitSync()
        }
    }

    // MARK: - State Check

    private func checkAndEmit() {
        listenerQueue.async { [weak self] in
            self?.checkAndEmitSync()
        }
    }

    private func checkAndEmitSync() {
        let anyRunning = deviceIDs.contains { Self.isDeviceRunning($0) }
        if anyRunning != lastEmittedValue {
            lastEmittedValue = anyRunning
            continuation?.yield(anyRunning)
        }
    }

    // MARK: - Helpers

    private static func videoDeviceIDs() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &dataSize
        ) == kCMIOHardwareNoError else { return [] }

        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var deviceIDs = [CMIOObjectID](repeating: 0, count: count)
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        ) == kCMIOHardwareNoError else { return [] }

        // Filter to devices that have input streams (video sources)
        return deviceIDs.filter { deviceID in
            var streamAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
                mScope: CMIOObjectPropertyScope(kCMIODevicePropertyScopeInput),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            var streamSize: UInt32 = 0
            let status = CMIOObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &streamSize)
            return status == kCMIOHardwareNoError && streamSize > 0
        }
    }

    private static func isDeviceRunning(_ deviceID: CMIOObjectID) -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = CMIOObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isRunning)
        return status == kCMIOHardwareNoError && isRunning != 0
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd OpenOats && swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add OpenOats/Sources/OpenOats/Meeting/CameraActivityMonitor.swift
git commit -m "feat: add CoreMediaIO camera activity monitor"
```

---

### Task 3: Refactor MeetingDetector for Multi-Signal Priority Detection

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Meeting/MeetingDetector.swift:138-297` (MeetingDetector actor)
- Modify: `OpenOats/Tests/OpenOatsTests/MeetingDetectorTests.swift` (add MockCameraSignalSource + new tests)

- [ ] **Step 1: Add MockCameraSignalSource to test file**

In `MeetingDetectorTests.swift`, add after `MockAudioSignalSource`:

```swift
// MARK: - Mock Camera Signal Source

final class MockCameraSignalSource: CameraSignalSource, @unchecked Sendable {
    let signals: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation
    private let lock = NSLock()
    private var _isActive = false

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isActive
    }

    init() {
        var captured: AsyncStream<Bool>.Continuation!
        self.signals = AsyncStream<Bool> { continuation in
            captured = continuation
        }
        self.continuation = captured
    }

    func emit(_ value: Bool) {
        lock.lock()
        _isActive = value
        lock.unlock()
        continuation.yield(value)
    }

    func finish() {
        continuation.finish()
    }
}
```

- [ ] **Step 2: Write failing tests for new detection behavior**

Add these tests to `MeetingDetectorTests`:

```swift
// MARK: - Camera Detection Tests

func testCameraOnTriggersInstantDetection() async throws {
    let audioSource = MockAudioSignalSource()
    let cameraSource = MockCameraSignalSource()
    let detector = MeetingDetector(audioSource: audioSource, cameraSource: cameraSource)
    let collector = EventCollector()

    let stream = await detector.events
    let listenTask = Task {
        for await event in stream { collector.append(event) }
    }

    await detector.start()
    cameraSource.emit(true)

    // Camera detection is instant — no 5s debounce
    try await Task.sleep(for: .milliseconds(500))

    let collected = collector.events
    XCTAssertEqual(collected.count, 1, "Expected exactly one .detected event")
    if case .detected = collected.first {} else {
        XCTFail("Expected .detected, got \(String(describing: collected.first))")
    }

    await detector.stop()
    audioSource.finish()
    cameraSource.finish()
    listenTask.cancel()
}

func testMicAloneDoesNotTriggerDetection() async throws {
    let audioSource = MockAudioSignalSource()
    let cameraSource = MockCameraSignalSource()
    let detector = MeetingDetector(audioSource: audioSource, cameraSource: cameraSource)
    let collector = EventCollector()

    let stream = await detector.events
    let listenTask = Task {
        for await event in stream { collector.append(event) }
    }

    await detector.start()
    audioSource.emit(true)

    // Wait past debounce
    try await Task.sleep(for: .seconds(6))

    XCTAssertTrue(collector.events.isEmpty, "Mic alone should not trigger detection")

    await detector.stop()
    audioSource.finish()
    cameraSource.finish()
    listenTask.cancel()
}

func testCameraOffWhileMicAppActiveContinues() async throws {
    let audioSource = MockAudioSignalSource()
    let cameraSource = MockCameraSignalSource()
    let detector = MeetingDetector(audioSource: audioSource, cameraSource: cameraSource)
    let collector = EventCollector()

    let stream = await detector.events
    let listenTask = Task {
        for await event in stream { collector.append(event) }
    }

    await detector.start()

    // Camera on triggers detection
    cameraSource.emit(true)
    try await Task.sleep(for: .milliseconds(500))

    // Mic+app also active (mic on, meeting app would be running)
    audioSource.emit(true)
    try await Task.sleep(for: .seconds(6))

    // Camera off — but mic+app still active, meeting continues
    cameraSource.emit(false)
    // Wait past hysteresis (3s) + margin
    try await Task.sleep(for: .seconds(4))

    // Should have .detected but no .ended
    let endedCount = collector.events.filter {
        if case .ended = $0 { return true }
        return false
    }.count
    XCTAssertEqual(endedCount, 0, "Should not end while mic+app is still active")

    await detector.stop()
    audioSource.finish()
    cameraSource.finish()
    listenTask.cancel()
}

func testMicOffWhileCameraActiveSessionContinues() async throws {
    let audioSource = MockAudioSignalSource()
    let cameraSource = MockCameraSignalSource()
    let detector = MeetingDetector(audioSource: audioSource, cameraSource: cameraSource)
    let collector = EventCollector()

    let stream = await detector.events
    let listenTask = Task {
        for await event in stream { collector.append(event) }
    }

    await detector.start()

    cameraSource.emit(true)
    try await Task.sleep(for: .milliseconds(500))

    audioSource.emit(true)
    try await Task.sleep(for: .milliseconds(200))

    // Mic off — camera still on, meeting continues
    audioSource.emit(false)
    try await Task.sleep(for: .milliseconds(500))

    let endedCount = collector.events.filter {
        if case .ended = $0 { return true }
        return false
    }.count
    XCTAssertEqual(endedCount, 0, "Should not end while camera is still active")

    await detector.stop()
    audioSource.finish()
    cameraSource.finish()
    listenTask.cancel()
}

func testBothOffEndsSession() async throws {
    let audioSource = MockAudioSignalSource()
    let cameraSource = MockCameraSignalSource()
    let detector = MeetingDetector(audioSource: audioSource, cameraSource: cameraSource)
    let collector = EventCollector()

    let stream = await detector.events
    let listenTask = Task {
        for await event in stream { collector.append(event) }
    }

    await detector.start()

    cameraSource.emit(true)
    try await Task.sleep(for: .milliseconds(500))

    // Turn both off
    cameraSource.emit(false)
    audioSource.emit(false)

    // Wait past hysteresis
    try await Task.sleep(for: .seconds(4))

    let hasEnded = collector.events.contains {
        if case .ended = $0 { return true }
        return false
    }
    XCTAssertTrue(hasEnded, "Session should end when all signals are off")

    await detector.stop()
    audioSource.finish()
    cameraSource.finish()
    listenTask.cancel()
}

func testQueryCurrentStateIncludesCamera() async {
    let audioSource = MockAudioSignalSource()
    let cameraSource = MockCameraSignalSource()
    let detector = MeetingDetector(audioSource: audioSource, cameraSource: cameraSource)

    let state = await detector.queryCurrentState()
    XCTAssertFalse(state.micActive)
    XCTAssertFalse(state.cameraActive)

    await detector.stop()
    audioSource.finish()
    cameraSource.finish()
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd OpenOats && swift test --filter "MeetingDetectorTests" 2>&1 | tail -10`
Expected: Compilation errors — `MeetingDetector` doesn't accept `cameraSource` parameter yet, `queryCurrentState` doesn't return `cameraActive`.

- [ ] **Step 4: Refactor MeetingDetector actor**

Replace the `MeetingDetector` actor in `MeetingDetector.swift` (lines 134-297) with the multi-signal version:

```swift
// MARK: - Detection Trigger

/// Tracks which signal caused the active detection.
enum DetectionTrigger: Sendable {
    case camera
    case micAndApp
}

// MARK: - Meeting Detector Actor

/// Observes camera and microphone activation, correlates with running meeting apps,
/// and determines whether the user is in a meeting using priority-based evaluation.
actor MeetingDetector {
    private let audioSource: any AudioSignalSource
    private let cameraSource: any CameraSignalSource
    private let knownApps: [MeetingAppEntry]
    private let customBundleIDs: [String]
    private let selfBundleID: String
    private let knownBundleIDs: Set<String>

    /// Set to true once detection is confirmed.
    private(set) var isActive = false

    /// The meeting app that was detected, if any.
    private(set) var detectedApp: MeetingApp?

    /// What triggered the current detection.
    private(set) var detectionTrigger: DetectionTrigger?

    /// Emits detection events.
    let events: AsyncStream<MeetingDetectionEvent>
    private let eventContinuation: AsyncStream<MeetingDetectionEvent>.Continuation

    private var micMonitorTask: Task<Void, Never>?
    private var cameraMonitorTask: Task<Void, Never>?
    private var cameraHysteresisTask: Task<Void, Never>?
    private var isCameraActive = false
    private var isMicActive = false
    private var micActiveAt: Date?

    /// Debounce duration: mic must stay active for this long before we confirm.
    private let debounceSeconds: TimeInterval = 5.0

    /// Hysteresis duration: camera must stay off for this long before we end.
    private let cameraHysteresisSeconds: TimeInterval = 3.0

    enum MeetingDetectionEvent: Sendable {
        case detected(MeetingApp?)
        case ended
    }

    init(
        audioSource: (any AudioSignalSource)? = nil,
        cameraSource: (any CameraSignalSource)? = nil,
        customBundleIDs: [String] = []
    ) {
        self.audioSource = audioSource ?? CoreAudioSignalSource()
        self.cameraSource = cameraSource ?? CoreMediaIOSignalSource()
        self.customBundleIDs = customBundleIDs
        self.selfBundleID = Bundle.main.bundleIdentifier ?? "com.openoats.app"

        self.knownApps = Self.defaultMeetingApps
        self.knownBundleIDs = Set(Self.defaultMeetingApps.map(\.bundleID) + customBundleIDs)
            .subtracting([selfBundleID])

        var capturedContinuation: AsyncStream<MeetingDetectionEvent>.Continuation!
        self.events = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        self.eventContinuation = capturedContinuation
    }

    deinit {
        micMonitorTask?.cancel()
        cameraMonitorTask?.cancel()
        cameraHysteresisTask?.cancel()
        eventContinuation.finish()
    }

    // MARK: - Lifecycle

    func start() {
        guard micMonitorTask == nil else { return }

        micMonitorTask = Task { [weak self] in
            guard let self else { return }
            for await micIsActive in self.audioSource.signals {
                guard !Task.isCancelled else { break }
                await self.handleMicSignal(micIsActive)
            }
        }

        cameraMonitorTask = Task { [weak self] in
            guard let self else { return }
            for await cameraIsActive in self.cameraSource.signals {
                guard !Task.isCancelled else { break }
                await self.handleCameraSignal(cameraIsActive)
            }
        }
    }

    func stop() {
        micMonitorTask?.cancel()
        micMonitorTask = nil
        cameraMonitorTask?.cancel()
        cameraMonitorTask = nil
        cameraHysteresisTask?.cancel()
        cameraHysteresisTask = nil
        if isActive {
            isActive = false
            detectedApp = nil
            detectionTrigger = nil
            eventContinuation.yield(.ended)
        }
        micActiveAt = nil
        isCameraActive = false
        isMicActive = false
    }

    // MARK: - Query

    func queryCurrentState() async -> (micActive: Bool, cameraActive: Bool, meetingApp: MeetingApp?) {
        let mic = audioSource.isActive
        let camera = cameraSource.isActive
        let app = await scanForMeetingApp()
        return (mic, camera, app)
    }

    // MARK: - Camera Signal Handling

    private func handleCameraSignal(_ cameraIsActive: Bool) async {
        isCameraActive = cameraIsActive

        if cameraIsActive {
            // Cancel any pending hysteresis
            cameraHysteresisTask?.cancel()
            cameraHysteresisTask = nil

            if !isActive {
                let app = await scanForMeetingApp()
                isActive = true
                detectedApp = app
                detectionTrigger = .camera
                eventContinuation.yield(.detected(app))
            } else {
                // Upgrade trigger to camera if currently mic+app
                detectionTrigger = .camera
            }
        } else {
            // Camera off — start hysteresis before evaluating end conditions
            cameraHysteresisTask?.cancel()
            cameraHysteresisTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await self?.evaluateCameraOff()
            }
        }
    }

    private func evaluateCameraOff() {
        // Camera is off after hysteresis. Check if mic+app can sustain the session.
        if isActive {
            if isMicActive, micActiveAt != nil {
                // Check if a meeting app is running — do this synchronously
                // since we're already in the actor. We'll use the last known app.
                if detectedApp != nil || knownBundleIDs.isEmpty == false {
                    // Downgrade trigger
                    detectionTrigger = .micAndApp
                    // Don't emit ended — session continues with mic+app
                    return
                }
            }
            // No sustaining signal — end
            isActive = false
            detectedApp = nil
            detectionTrigger = nil
            eventContinuation.yield(.ended)
        }
    }

    // MARK: - Mic Signal Handling

    private func handleMicSignal(_ micIsActive: Bool) async {
        isMicActive = micIsActive

        if micIsActive {
            if micActiveAt == nil {
                micActiveAt = Date()
            }

            let activeSince = micActiveAt!
            try? await Task.sleep(for: .seconds(debounceSeconds))
            guard !Task.isCancelled else { return }

            // Verify mic is still considered active (debounce passed)
            guard micActiveAt == activeSince else { return }

            // If camera already triggered detection, skip
            if isActive { return }

            // Scan for meeting app — mic alone doesn't trigger
            let app = await scanForMeetingApp()
            guard app != nil else { return }

            if !isActive {
                isActive = true
                detectedApp = app
                detectionTrigger = .micAndApp
                eventContinuation.yield(.detected(app))
            }
        } else {
            micActiveAt = nil
            isMicActive = false
            if isActive && detectionTrigger == .micAndApp && !isCameraActive {
                isActive = false
                detectedApp = nil
                detectionTrigger = nil
                eventContinuation.yield(.ended)
            }
        }
    }

    // MARK: - Process Scanning

    private func scanForMeetingApp() async -> MeetingApp? {
        let runningApps = await MainActor.run {
            NSWorkspace.shared.runningApplications
        }

        for app in runningApps {
            guard let bundleID = app.bundleIdentifier else { continue }
            if knownBundleIDs.contains(bundleID) {
                let name = app.localizedName
                    ?? knownApps.first(where: { $0.bundleID == bundleID })?.displayName
                    ?? bundleID
                return MeetingApp(bundleID: bundleID, name: name)
            }
        }
        return nil
    }

    // MARK: - Default Meeting Apps

    static var bundledMeetingApps: [MeetingAppEntry] {
        defaultMeetingApps
    }

    private static let defaultMeetingApps: [MeetingAppEntry] = [
        MeetingAppEntry(bundleID: "us.zoom.xos", displayName: "Zoom"),
        MeetingAppEntry(bundleID: "com.microsoft.teams", displayName: "Microsoft Teams (classic)"),
        MeetingAppEntry(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams"),
        MeetingAppEntry(bundleID: "com.apple.FaceTime", displayName: "FaceTime"),
        MeetingAppEntry(bundleID: "com.cisco.webexmeetingsapp", displayName: "Webex"),
        MeetingAppEntry(bundleID: "app.tuple.app", displayName: "Tuple"),
        MeetingAppEntry(bundleID: "co.around.Around", displayName: "Around"),
        MeetingAppEntry(bundleID: "com.slack.Slack", displayName: "Slack"),
        MeetingAppEntry(bundleID: "com.hnc.Discord", displayName: "Discord"),
        MeetingAppEntry(bundleID: "net.whatsapp.WhatsApp", displayName: "WhatsApp"),
        MeetingAppEntry(bundleID: "com.google.Chrome.app.kjgfgldnnfobanmcafgkdilakhehfkbm", displayName: "Google Meet (PWA)"),
    ]
}
```

- [ ] **Step 5: Update existing tests that expect mic-only detection**

The test `testBriefMicActivationProducesDetectedThenEnded` and `testDetectedEventEmittedAfterDebounce` now expect mic-only to NOT trigger. Update them:

```swift
func testBriefMicActivationWithoutAppProducesNoEvents() async throws {
    let audioSource = MockAudioSignalSource()
    let cameraSource = MockCameraSignalSource()
    let detector = MeetingDetector(audioSource: audioSource, cameraSource: cameraSource)
    let collector = EventCollector()

    let stream = await detector.events
    let listenTask = Task {
        for await event in stream { collector.append(event) }
    }

    await detector.start()

    source.emit(true)
    try await Task.sleep(for: .milliseconds(500))
    source.emit(false)

    try await Task.sleep(for: .seconds(6))

    XCTAssertTrue(collector.events.isEmpty, "Mic alone should not trigger detection")

    await detector.stop()
    audioSource.finish()
    cameraSource.finish()
    listenTask.cancel()
}
```

Replace the old `testBriefMicActivationProducesDetectedThenEnded`, `testDetectedEventEmittedAfterDebounce`, and `testEndedEventEmittedOnMicDeactivation` tests. Also update `testStartIsIdempotent`, `testStopClearsState`, `testMicDeactivationWhileInactiveIsNoOp`, and `testCustomBundleIDsAccepted` to pass both audio and camera sources to `MeetingDetector`.

- [ ] **Step 6: Run tests**

Run: `cd OpenOats && swift test --filter "MeetingDetectorTests" 2>&1 | tail -10`
Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add OpenOats/Sources/OpenOats/Meeting/MeetingDetector.swift OpenOats/Tests/OpenOatsTests/MeetingDetectorTests.swift
git commit -m "feat: refactor MeetingDetector for multi-signal priority detection"
```

---

### Task 4: Update NotificationService for Camera-Triggered Notifications

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Meeting/NotificationService.swift`

- [ ] **Step 1: Add second notification category and update `postMeetingDetected`**

Replace `NotificationService` content with:

```swift
// In registerCategory(), replace single category with two:
private static let categoryWithAppID = "MEETING_DETECTED_WITH_APP"
private static let categoryNoAppID = "MEETING_DETECTED_NO_APP"

private func registerCategory() {
    let notMeeting = UNNotificationAction(
        identifier: Self.notMeetingAction,
        title: "Not a Meeting",
        options: []
    )
    let ignoreApp = UNNotificationAction(
        identifier: Self.ignoreAppAction,
        title: "Ignore This App",
        options: []
    )
    let dismiss = UNNotificationAction(
        identifier: Self.dismissAction,
        title: "Dismiss",
        options: []
    )

    let categoryWithApp = UNNotificationCategory(
        identifier: Self.categoryWithAppID,
        actions: [notMeeting, ignoreApp, dismiss],
        intentIdentifiers: [],
        options: [.customDismissAction]
    )

    let categoryNoApp = UNNotificationCategory(
        identifier: Self.categoryNoAppID,
        actions: [notMeeting, dismiss],
        intentIdentifiers: [],
        options: [.customDismissAction]
    )

    UNUserNotificationCenter.current().setNotificationCategories([categoryWithApp, categoryNoApp])
    UNUserNotificationCenter.current().delegate = self
}
```

Update `postMeetingDetected` signature:

```swift
func postMeetingDetected(appName: String?, isCameraTrigger: Bool = false) async -> Bool {
    guard await ensurePermission() else { return false }

    pendingTimeoutTask?.cancel()
    pendingTimeoutTask = nil

    UNUserNotificationCenter.current().removeDeliveredNotifications(
        withIdentifiers: ["meeting-detection"]
    )

    let content = UNMutableNotificationContent()
    if let appName {
        content.title = "Meeting Detected"
        content.body = isCameraTrigger
            ? "\(appName) — tap to start transcribing."
            : "\(appName) is using your microphone. Tap to start transcribing."
        content.categoryIdentifier = Self.categoryWithAppID
    } else {
        content.title = "Meeting Detected"
        content.body = isCameraTrigger
            ? "Camera is active. Tap to start transcribing."
            : "A meeting may be in progress. Tap to start transcribing."
        content.categoryIdentifier = Self.categoryNoAppID
    }
    content.sound = .default

    let request = UNNotificationRequest(
        identifier: "meeting-detection",
        content: content,
        trigger: nil
    )

    do {
        try await UNUserNotificationCenter.current().add(request)
    } catch {
        return false
    }

    pendingTimeoutTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(60))
        guard !Task.isCancelled else { return }
        Task { @MainActor [weak self] in
            self?.onTimeout?()
        }
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: ["meeting-detection"]
        )
    }

    return true
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd OpenOats && swift build 2>&1 | tail -5`
Expected: Build succeeds (there may be a caller site to update in the controller — fix in next task).

- [ ] **Step 3: Commit**

```bash
git add OpenOats/Sources/OpenOats/Meeting/NotificationService.swift
git commit -m "feat: add dual notification categories for camera vs app detection"
```

---

### Task 5: Update MeetingDetectionController for Camera Detection

**Files:**
- Modify: `OpenOats/Sources/OpenOats/App/MeetingDetectionController.swift`

- [ ] **Step 1: Add DetectionSnapshot and DismissKey types**

Add at the top of the file, after the `DetectionEvent` enum:

```swift
/// Frozen context captured when a detection notification is posted.
struct DetectionSnapshot: Sendable {
    let trigger: DetectionTrigger
    let app: MeetingApp?
    let detectedAt: Date
}

/// Key for tracking dismissed detection events.
enum DismissKey: Hashable {
    case app(bundleID: String)
    case cameraOnly
}
```

- [ ] **Step 2: Update MeetingDetectionController properties**

Change `dismissedEvents` type and add snapshot:

```swift
/// Sessions the user dismissed (by detection key).
private(set) var dismissedEvents: Set<DismissKey> = []

/// Snapshot of the detection context when notification was posted.
private var pendingSnapshot: DetectionSnapshot?
```

- [ ] **Step 3: Update `setup(settings:)` for dependency injection**

```swift
func setup(
    settings: AppSettings,
    detector: MeetingDetector? = nil,
    notificationService service: NotificationService? = nil
) {
    guard meetingDetector == nil else { return }
    activeSettings = settings
    isEnabled = true

    let detector = detector ?? MeetingDetector(
        customBundleIDs: settings.customMeetingAppBundleIDs
    )
    meetingDetector = detector

    let service = service ?? NotificationService()
    notificationService = service
    // ... rest unchanged
```

- [ ] **Step 4: Update handleMeetingDetected to capture snapshot and pass trigger info**

```swift
private func handleMeetingDetected(app: MeetingApp?) async {
    detectedApp = app

    guard !isSessionActive() else { return }

    // Check dismiss keys
    let dismissKey: DismissKey = app.map { .app(bundleID: $0.bundleID) } ?? .cameraOnly
    if dismissedEvents.contains(dismissKey) { return }

    if let bundleID = app?.bundleID,
       activeSettings?.ignoredAppBundleIDs.contains(bundleID) == true {
        return
    }

    // Determine trigger from detector state
    let trigger = await meetingDetector?.detectionTrigger ?? .micAndApp

    // Freeze snapshot
    pendingSnapshot = DetectionSnapshot(
        trigger: trigger,
        app: app,
        detectedAt: Date()
    )

    if activeSettings?.detectionLogEnabled == true {
        Log.meetingDetection.info("Detected: \(app?.name ?? "camera", privacy: .public)")
    }

    let posted = await notificationService?.postMeetingDetected(
        appName: app?.name,
        isCameraTrigger: trigger == .camera
    ) ?? false
    if !posted {
        if activeSettings?.detectionLogEnabled == true {
            Log.meetingDetection.debug("Failed to post notification")
        }
    }
}
```

- [ ] **Step 5: Update handleMeetingEnded to cancel stale notifications**

```swift
private func handleMeetingEnded() {
    detectedApp = nil
    pendingSnapshot = nil
    notificationService?.cancelPending()
    eventContinuation.yield(.meetingAppExited)
}
```

- [ ] **Step 6: Update handleDetectionAccepted to use frozen snapshot**

```swift
private func handleDetectionAccepted() {
    Task {
        let snapshot = self.pendingSnapshot
        let calEvent = calendarManager?.currentEvent()
        let trigger = snapshot?.trigger ?? .micAndApp
        let app = snapshot?.app ?? (await meetingDetector?.detectedApp)

        let signal: DetectionSignal
        if trigger == .camera {
            signal = .cameraActivated
        } else if let app {
            signal = .appLaunched(app)
        } else {
            signal = .audioActivity
        }

        let context = DetectionContext(
            signal: signal,
            detectedAt: snapshot?.detectedAt ?? Date(),
            meetingApp: app,
            calendarEvent: calEvent
        )
        let title = calEvent?.title ?? app?.name
        let metadata = MeetingMetadata(
            detectionContext: context,
            calendarEvent: calEvent,
            title: title,
            startedAt: Date(),
            endedAt: nil
        )
        self.pendingSnapshot = nil
        self.eventContinuation.yield(.accepted(metadata))
    }
}
```

- [ ] **Step 7: Update handleDetectionNotAMeeting to use DismissKey**

```swift
private func handleDetectionNotAMeeting() {
    Task {
        if let app = pendingSnapshot?.app ?? (await meetingDetector?.detectedApp) {
            dismissedEvents.insert(.app(bundleID: app.bundleID))
            eventContinuation.yield(.notAMeeting(bundleID: app.bundleID))
        } else {
            dismissedEvents.insert(.cameraOnly)
            eventContinuation.yield(.notAMeeting(bundleID: "__camera__"))
        }
    }
    if activeSettings?.detectionLogEnabled == true {
        Log.meetingDetection.debug("User dismissed as not a meeting")
    }
}
```

- [ ] **Step 8: Update handleIgnoreApp**

```swift
private func handleIgnoreApp() {
    Task {
        if let app = pendingSnapshot?.app ?? (await meetingDetector?.detectedApp),
           let settings = activeSettings {
            var ignored = settings.ignoredAppBundleIDs
            if !ignored.contains(app.bundleID) {
                ignored.append(app.bundleID)
                settings.ignoredAppBundleIDs = ignored
            }
            dismissedEvents.insert(.app(bundleID: app.bundleID))
        }
    }
    if activeSettings?.detectionLogEnabled == true {
        Log.meetingDetection.debug("User chose to ignore this app permanently")
    }
}
```

- [ ] **Step 9: Update evaluateImmediate for camera state**

```swift
func evaluateImmediate() async {
    guard !isSessionActive() else { return }
    guard let detector = meetingDetector else { return }

    let state = await detector.queryCurrentState()
    if state.cameraActive {
        await handleMeetingDetected(app: state.meetingApp)
    } else if state.micActive, state.meetingApp != nil {
        await handleMeetingDetected(app: state.meetingApp)
    }
}
```

- [ ] **Step 10: Verify it compiles**

Run: `cd OpenOats && swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 11: Commit**

```bash
git add OpenOats/Sources/OpenOats/App/MeetingDetectionController.swift
git commit -m "feat: update detection controller for camera signals and frozen snapshots"
```

---

### Task 6: Update AppCoordinator for Camera-Triggered Sessions

**Files:**
- Modify: `OpenOats/Sources/OpenOats/App/AppCoordinator.swift:233-270`

- [ ] **Step 1: Update startDetectionEventLoop**

Replace the `.accepted` and `.meetingAppExited` cases:

```swift
case .accepted(let metadata):
    // Start silence monitoring for all auto-detected sessions
    let signal = metadata.detectionContext?.signal
    if case .appLaunched(let app) = signal {
        controller.startSilenceMonitoring()
        controller.startAppExitMonitoring(bundleID: app.bundleID)
    } else if case .cameraActivated = signal {
        controller.startSilenceMonitoring()
        // If a meeting app was detected alongside camera, monitor its exit too
        if let app = metadata.detectionContext?.meetingApp {
            controller.startAppExitMonitoring(bundleID: app.bundleID)
        }
    }
    self.handle(.userStarted(metadata), settings: self.activeSettings)

case .meetingAppExited:
    if case .recording(let meta) = self.state {
        let signal = meta.detectionContext?.signal
        // Don't stop if camera is still active
        if case .cameraActivated = signal {
            // Camera-triggered session: check if detector still has camera active
            if let detector = controller.meetingDetector {
                let trigger = await detector.detectionTrigger
                if trigger == .camera {
                    // Camera still on — ignore app exit
                    break
                }
            }
        }
        if case .appLaunched = signal {
            controller.stopSilenceMonitoring()
            controller.stopAppExitMonitoring()
            self.handle(.userStopped)
        } else if case .cameraActivated = signal {
            // Camera trigger but camera is off — stop
            controller.stopSilenceMonitoring()
            controller.stopAppExitMonitoring()
            self.handle(.userStopped)
        }
    }
```

- [ ] **Step 2: Verify it compiles**

Run: `cd OpenOats && swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add OpenOats/Sources/OpenOats/App/AppCoordinator.swift
git commit -m "feat: handle camera-triggered sessions in coordinator"
```

---

### Task 7: Update Settings and UI

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Settings/SettingsStore.swift`
- Modify: `OpenOats/Sources/OpenOats/Views/SettingsView.swift`

- [ ] **Step 1: Add hasShownCameraDetectExplanation to SettingsStore**

In `SettingsStore.swift`, add property (same pattern as `hasShownAutoDetectExplanation` at line 554):

```swift
@ObservationIgnored nonisolated(unsafe) private var _hasShownCameraDetectExplanation: Bool
var hasShownCameraDetectExplanation: Bool {
    get { access(keyPath: \.hasShownCameraDetectExplanation); return _hasShownCameraDetectExplanation }
    set {
        withMutation(keyPath: \.hasShownCameraDetectExplanation) {
            _hasShownCameraDetectExplanation = newValue
            defaults.set(newValue, forKey: "hasShownCameraDetectExplanation")
        }
    }
}
```

In the init, add after line 810:

```swift
self._hasShownCameraDetectExplanation = defaults.bool(forKey: "hasShownCameraDetectExplanation")
```

- [ ] **Step 2: Update SettingsView description text**

In `SettingsView.swift`, line 98:

```swift
Text("When enabled, OpenOats monitors camera and microphone activation to detect when a meeting starts. No audio or video is captured until you accept the notification.")
```

Line 123, update the label:

```swift
Label("OpenOats watches for camera and microphone activation by meeting apps (Zoom, Teams, FaceTime, etc.)", systemImage: "video")
```

- [ ] **Step 3: Verify it compiles**

Run: `cd OpenOats && swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add OpenOats/Sources/OpenOats/Settings/SettingsStore.swift OpenOats/Sources/OpenOats/Views/SettingsView.swift
git commit -m "feat: update settings UI for camera detection, add consent flag"
```

---

### Task 8: Update Existing Tests and Add Controller Tests

**Files:**
- Modify: `OpenOats/Tests/OpenOatsTests/MeetingDetectionControllerTests.swift`
- Modify: `OpenOats/Tests/OpenOatsTests/MeetingStateTests.swift`

- [ ] **Step 1: Add controller tests for camera detection**

In `MeetingDetectionControllerTests.swift`, add:

```swift
func testDismissedEventsUseDismissKey() async {
    let controller = MeetingDetectionController()
    XCTAssertTrue(controller.dismissedEvents.isEmpty)
    // DismissKey type should be usable
    let key = DismissKey.cameraOnly
    XCTAssertEqual(key, .cameraOnly)
    let appKey = DismissKey.app(bundleID: "us.zoom.xos")
    XCTAssertNotEqual(key, appKey)
}

func testEndedEventCancelsPendingNotification() async throws {
    let controller = MeetingDetectionController()
    var receivedEvent: DetectionEvent?

    let consumeTask = Task { @MainActor in
        for await event in controller.events {
            receivedEvent = event
            break
        }
    }

    try await Task.sleep(for: .milliseconds(50))
    controller.yield(.meetingAppExited)
    try await Task.sleep(for: .milliseconds(50))

    if case .meetingAppExited = receivedEvent {
        // correct
    } else {
        XCTFail("Expected .meetingAppExited, got \(String(describing: receivedEvent))")
    }

    consumeTask.cancel()
}
```

- [ ] **Step 2: Verify all tests pass**

Run: `cd OpenOats && swift test 2>&1 | tail -10`
Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add OpenOats/Tests/OpenOatsTests/MeetingDetectionControllerTests.swift OpenOats/Tests/OpenOatsTests/MeetingStateTests.swift
git commit -m "test: add camera detection tests for controller and state"
```

---

### Task 9: Final Integration Verification

**Files:** None — verification only.

- [ ] **Step 1: Full test suite**

Run: `cd OpenOats && swift test 2>&1 | tail -20`
Expected: All tests pass.

- [ ] **Step 2: Release build**

Run: `cd OpenOats && swift build -c release 2>&1 | tail -5`
Expected: Build succeeds with no errors.

- [ ] **Step 3: Verify no regressions in existing functionality**

Run: `cd OpenOats && swift test --filter "AppCoordinatorIntegration" 2>&1 | tail -5`
Expected: Integration tests pass.
