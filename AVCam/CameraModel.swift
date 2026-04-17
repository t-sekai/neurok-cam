/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
An object that provides the interface to the features of the camera.
*/

import SwiftUI
import Combine
import CoreBluetooth

private enum RemoteDirectorConfiguration {
    static let directorWebSocketURLDefaultsKey = "DirectorWebSocketURL"
    static let directorWebSocketURLInfoKey = "DirectorWebSocketURL"
    static let directorDeviceNameDefaultsKey = "DirectorDeviceName"
}

private enum ManualControlConfiguration {
    static let manualControlStateDefaultsKey = "ManualCameraControlState"
}

private enum TentacleSyncConfiguration {
    static let maxSamples = 160
    static let minSamplesForFit = 8
    static let fitIntervalSeconds: TimeInterval = 0.4
    static let hardReplaceThresholdMS = 100.0
    static let blendAlpha = 0.2
}

/// An object that provides the interface to the features of the camera.
///
/// This object provides the default implementation of the `Camera` protocol, which defines the interface
/// to configure the camera hardware and capture media. `CameraModel` doesn't perform capture itself, but is an
/// `@Observable` type that mediates interactions between the app's SwiftUI views and `CaptureService`.
///
/// For SwiftUI previews and Simulator, the app uses `PreviewCameraModel` instead.
///
@MainActor
@Observable
final class CameraModel: Camera {
    
    /// The current status of the camera, such as unauthorized, running, or failed.
    private(set) var status = CameraStatus.unknown
    
    /// The current state of photo or movie capture.
    private(set) var captureActivity = CaptureActivity.idle
    
    /// A Boolean value that indicates whether the app is currently switching video devices.
    private(set) var isSwitchingVideoDevices = false
    
    /// A Boolean value that indicates whether the camera prefers showing a minimized set of UI controls.
    private(set) var prefersMinimizedUI = false
    
    /// A Boolean value that indicates whether the app is currently switching capture modes.
    private(set) var isSwitchingModes = false
    
    /// A Boolean value that indicates whether to show visual feedback when capture begins.
    private(set) var shouldFlashScreen = false
    
    /// A thumbnail for the last captured photo or video.
    private(set) var thumbnail: CGImage?
    
    /// An error that indicates the details of an error during photo or movie capture.
    private(set) var error: Error?
    
    /// An object that provides the connection between the capture session and the video preview layer.
    var previewSource: PreviewSource { captureService.previewSource }
    
    /// A Boolean that indicates whether the camera supports HDR video recording.
    private(set) var isHDRVideoSupported = false
    
    /// An object that saves captured media to a person's Photos library.
    private let mediaLibrary = MediaLibrary()

    /// An object that stores captured videos in the app sandbox.
    private let localVideoStore = LocalVideoStore()
    
    /// An object that manages the app's capture functionality.
    private let captureService = CaptureService()

    /// An object that manages Tentacle Sync E timecode over BLE.
    private let tentacleTimecodeService: TentacleTimecodeService

    /// An object that manages remote recording control from a laptop director.
    private let remoteDirectorClient: RemoteDirectorClient

    /// The current Bluetooth connection state for Tentacle timecode.
    private(set) var tentacleConnectionState = TentacleConnectionState.idle

    /// The most recently received Tentacle timecode packet.
    private(set) var tentacleTimecode: TentacleTimecode?

    /// The continuously advancing Tentacle timecode display value.
    private(set) var displayedTentacleTimecode = ""

    /// The recording timer display value (`HH:MM:SS.mmm`) while actively recording.
    private(set) var displayedRecordingTimecode = ""

    /// The frame rate for the continuously advancing Tentacle timecode display value.
    private(set) var displayedTentacleFPS: Int?

    /// The WebSocket endpoint for the laptop director.
    var directorWebSocketURL = "" {
        didSet { handleDirectorWebSocketURLChange(from: oldValue) }
    }

    /// User-configurable device name shown to the laptop director.
    var directorDeviceName = UIDevice.current.name {
        didSet { handleDirectorDeviceNameChange(from: oldValue) }
    }

    /// Persisted list of local video files in the app sandbox.
    private(set) var localVideoURLs = [URL]()

    /// The current values and lock states for manual camera controls.
    var manualControlState = ManualCameraControlState.default {
        didSet { handleManualControlStateChange(from: oldValue) }
    }

    /// The capabilities and supported numeric ranges for manual camera controls.
    private(set) var manualControlCapabilities = ManualCameraControlCapabilities.unavailable

    /// A Boolean value that indicates whether this camera is armed for remote trigger.
    private(set) var isRemoteArmed = false

    /// Prevents manual-control didSet recursion when updates originate from capture-device sync.
    private var isUpdatingManualControlState = false

    /// Tracks whether internal code is setting the capture mode directly.
    private var isApplyingCaptureModeInternally = false

    /// The most recent prepared remote start command.
    private var pendingRemoteStart: PreparedRemoteStart?

    /// Task for a scheduled remote start.
    private var remoteStartTask: Task<Void, Never>?

    /// Task for a scheduled remote stop.
    private var remoteStopTask: Task<Void, Never>?

    /// Task that advances Tentacle timecode display between BLE updates.
    private var tentacleClockTask: Task<Void, Never>?

    /// Anchor for continuous Tentacle timecode display.
    private var tentacleClockAnchor: TentacleClockAnchor?

    /// Fitted local-to-remote Tentacle clock model.
    private var tentacleClockModel: TentacleClockModel?

    /// Rolling buffer of recent Tentacle sync samples.
    private var tentacleSyncSamples = [TentacleSyncSample]()

    /// Day-rollover offset in frames applied while unwrapping samples.
    private var tentacleRolloverOffsetFrames = 0

    /// Last unwrapped frame value observed from Tentacle.
    private var lastTentacleUnwrappedFrame: Int?

    /// Last uptime at which model fitting ran.
    private var lastTentacleModelFitUptime: TimeInterval = 0

    /// Last displayed frame-of-day to avoid redundant UI publishes.
    private var lastPublishedTentacleFrameOfDay: Int?

    /// Task that advances the local recording timer display.
    private var recordingClockTask: Task<Void, Never>?

    /// Anchor for a recording timer display seeded from Tentacle at record start.
    private var recordingClockAnchor: RecordingClockAnchor?

    /// Tentacle timecode frozen at recording start for metadata.
    private var recordingStartTimecodeMetadata: RecordingStartTimecodeMetadata?

    /// Calibration snapshot captured at recording start and persisted as sidecar JSON on stop.
    private var pendingRecordingCalibrationJSON: Data?

    /// Ensures camera state observers are only attached once.
    private var hasAttachedStateObservers = false
    
    /// Persistent state shared between the app and capture extension.
    private var cameraState = CameraState()

    private struct TentacleClockAnchor {
        let referenceTimecode: TentacleTimecode
        let referenceUptime: TimeInterval
    }

    private struct TentacleSyncSample {
        let localUptime: TimeInterval
        let remoteFramesOfDay: Int
        let unwrappedRemoteFrames: Int
        let fps: Int
    }

    private struct TentacleClockModel {
        let fps: Int
        let slopeFramesPerSecond: Double
        let interceptFrames: Double

        func predictUnwrappedFrames(at uptime: TimeInterval) -> Double {
            (slopeFramesPerSecond * uptime) + interceptFrames
        }

        func predictFramesOfDay(at uptime: TimeInterval) -> Int {
            let framesPerDay = max(1, 24 * 60 * 60 * fps)
            let roundedFrames = Int(predictUnwrappedFrames(at: uptime).rounded())
            return ((roundedFrames % framesPerDay) + framesPerDay) % framesPerDay
        }
    }

    private struct RecordingClockAnchor {
        let baseMillisecondsOfDay: Int
        let startUptime: TimeInterval
    }
    
    init() {
        tentacleTimecodeService = TentacleTimecodeService()
        remoteDirectorClient = RemoteDirectorClient()

        tentacleTimecodeService.onUpdate = { [weak self] connectionState, timecode in
            guard let self else { return }
            let wasConnected = self.tentacleConnectionState.isConnected
            self.tentacleConnectionState = connectionState
            self.tentacleTimecode = timecode
            if connectionState.isConnected, let timecode {
                self.ingestTentacleTimecode(timecode, wasPreviouslyConnected: wasConnected)
            } else if wasConnected && !connectionState.isConnected {
                self.resetTentacleClockModel()
            }
            self.remoteDirectorClient.sendStatusSoon()
        }

        remoteDirectorClient.statusProvider = { [weak self] in
            guard let self else { return .empty }
            return self.remoteStatusPayload()
        }

        remoteDirectorClient.deviceNameProvider = { [weak self] in
            self?.directorDeviceName ?? UIDevice.current.name
        }

        remoteDirectorClient.commandHandler = { [weak self] command in
            guard let self else {
                return .failure("Camera model unavailable.")
            }
            return await self.handleRemoteDirectorCommand(command)
        }

        directorWebSocketURL = currentDirectorWebSocketURL()
        directorDeviceName = currentDirectorDeviceName()
        isUpdatingManualControlState = true
        manualControlState = loadManualControlState()
        isUpdatingManualControlState = false
    }

    deinit {
        tentacleTimecodeService.stop()
        let remoteDirectorClient = remoteDirectorClient
        Task { @MainActor in
            remoteDirectorClient.stop()
        }
    }

    private func handleDirectorWebSocketURLChange(from oldValue: String) {
        let normalized = directorWebSocketURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized != directorWebSocketURL {
            directorWebSocketURL = normalized
            return
        }

        guard normalized != oldValue else { return }

        if normalized.isEmpty {
            UserDefaults.standard.removeObject(forKey: RemoteDirectorConfiguration.directorWebSocketURLDefaultsKey)
        } else {
            UserDefaults.standard.set(normalized, forKey: RemoteDirectorConfiguration.directorWebSocketURLDefaultsKey)
        }

        guard status == .running else { return }
        remoteDirectorClient.stop()
        remoteDirectorClient.start()
    }

    private func currentDirectorWebSocketURL() -> String {
        if let defaultsURL = UserDefaults.standard.string(forKey: RemoteDirectorConfiguration.directorWebSocketURLDefaultsKey) {
            return defaultsURL
        }
        if let infoURL = Bundle.main.object(forInfoDictionaryKey: RemoteDirectorConfiguration.directorWebSocketURLInfoKey) as? String {
            return infoURL
        }
        return ""
    }

    private func handleDirectorDeviceNameChange(from oldValue: String) {
        let normalized = directorDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = normalized.isEmpty ? UIDevice.current.name : normalized
        if resolved != directorDeviceName {
            directorDeviceName = resolved
            return
        }

        guard resolved != oldValue else { return }
        UserDefaults.standard.set(resolved, forKey: RemoteDirectorConfiguration.directorDeviceNameDefaultsKey)

        guard status == .running else { return }
        remoteDirectorClient.stop()
        remoteDirectorClient.start()
    }

    private func currentDirectorDeviceName() -> String {
        if let defaultsValue = UserDefaults.standard.string(forKey: RemoteDirectorConfiguration.directorDeviceNameDefaultsKey),
           !defaultsValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return defaultsValue
        }
        return UIDevice.current.name
    }

    private func handleManualControlStateChange(from oldValue: ManualCameraControlState) {
        guard !isUpdatingManualControlState else { return }
        guard manualControlState != oldValue else { return }

        persistManualControlState(manualControlState)
        guard status == .running else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.applyManualControlStateToDevice()
        }
    }

    private func applyManualControlStateToDevice() async {
        let snapshot = await captureService.applyManualControlState(manualControlState)

        isUpdatingManualControlState = true
        manualControlCapabilities = snapshot.capabilities
        manualControlState = snapshot.state
        isUpdatingManualControlState = false

        persistManualControlState(snapshot.state)
        remoteDirectorClient.sendStatusNow()
    }

    private func loadManualControlState() -> ManualCameraControlState {
        guard let data = UserDefaults.standard.data(forKey: ManualControlConfiguration.manualControlStateDefaultsKey) else {
            return .default
        }
        guard let decoded = try? JSONDecoder().decode(ManualCameraControlState.self, from: data) else {
            return .default
        }
        return decoded
    }

    private func persistManualControlState(_ state: ManualCameraControlState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: ManualControlConfiguration.manualControlStateDefaultsKey)
    }

    private func seedTentacleClock(with timecode: TentacleTimecode, at uptime: TimeInterval) {
        tentacleClockAnchor = TentacleClockAnchor(referenceTimecode: timecode, referenceUptime: uptime)
        displayedTentacleTimecode = timecode.formatted
        displayedTentacleFPS = timecode.fps
        lastPublishedTentacleFrameOfDay = timecode.totalFramesOfDay
        startTentacleClockIfNeeded()
    }

    private func startTentacleClockIfNeeded() {
        guard tentacleClockTask == nil else { return }
        tentacleClockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000)
                guard let self else { break }
                self.refreshTentacleClock()
            }
        }
    }

    private func refreshTentacleClock() {
        guard let current = currentTentacleTimecode() else { return }
        let frameOfDay = current.totalFramesOfDay
        guard frameOfDay != lastPublishedTentacleFrameOfDay else { return }

        displayedTentacleTimecode = current.formatted
        displayedTentacleFPS = current.fps
        lastPublishedTentacleFrameOfDay = frameOfDay
    }

    private func currentTentacleTimecode() -> TentacleTimecode? {
        guard tentacleConnectionState.isConnected else { return nil }
        let now = ProcessInfo.processInfo.systemUptime

        if let model = tentacleClockModel {
            return timecodeFrom(totalFramesOfDay: model.predictFramesOfDay(at: now), fps: model.fps)
        }

        guard let anchor = tentacleClockAnchor else {
            return tentacleTimecode
        }
        let elapsed = max(0, now - anchor.referenceUptime)
        return anchor.referenceTimecode.advanced(by: elapsed)
    }

    private func currentRecordingStartMetadata() -> RecordingStartTimecodeMetadata? {
        guard let timecode = currentTentacleTimecode() else { return nil }
        return RecordingStartTimecodeMetadata(timecode: timecode.formatted,
                                              fps: timecode.fps,
                                              source: "tentacle_sync_e")
    }

    private func startRecordingClock(seedTimecode: TentacleTimecode?) {
        let baseMilliseconds = seedTimecode.map { millisecondsOfDay(from: $0) } ?? 0
        recordingClockAnchor = RecordingClockAnchor(baseMillisecondsOfDay: baseMilliseconds,
                                                    startUptime: ProcessInfo.processInfo.systemUptime)
        displayedRecordingTimecode = formatClockWithMilliseconds(millisecondsOfDay: baseMilliseconds)

        recordingClockTask?.cancel()
        recordingClockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000)
                guard let self else { break }
                self.refreshRecordingClock()
            }
        }
    }

    private func stopRecordingClock() {
        recordingClockTask?.cancel()
        recordingClockTask = nil
        recordingClockAnchor = nil
        displayedRecordingTimecode = ""
    }

    private func refreshRecordingClock() {
        guard let anchor = recordingClockAnchor else { return }
        let elapsedUptime = max(0, ProcessInfo.processInfo.systemUptime - anchor.startUptime)
        let elapsedMilliseconds = Int((elapsedUptime * 1000).rounded(.down))

        let dayMilliseconds = 24 * 60 * 60 * 1000
        let totalMilliseconds = (anchor.baseMillisecondsOfDay + elapsedMilliseconds) % dayMilliseconds
        displayedRecordingTimecode = formatClockWithMilliseconds(millisecondsOfDay: totalMilliseconds)
    }

    private func millisecondsOfDay(from timecode: TentacleTimecode) -> Int {
        let secondsMilliseconds = timecode.secondsOfDay * 1000
        let frameMilliseconds = Int((Double(timecode.frames) / Double(max(timecode.fps, 1)) * 1000.0).rounded(.down))
        return secondsMilliseconds + frameMilliseconds
    }

    private func formatClockWithMilliseconds(millisecondsOfDay: Int) -> String {
        let dayMilliseconds = 24 * 60 * 60 * 1000
        let normalized = ((millisecondsOfDay % dayMilliseconds) + dayMilliseconds) % dayMilliseconds
        let totalSeconds = normalized / 1000
        let milliseconds = normalized % 1000

        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
    }

    private func ingestTentacleTimecode(_ timecode: TentacleTimecode, wasPreviouslyConnected: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        let needsHardReset = !wasPreviouslyConnected || displayedTentacleFPS != timecode.fps
        if needsHardReset {
            resetTentacleClockModel()
            seedTentacleClock(with: timecode, at: now)
        } else if tentacleClockAnchor == nil {
            seedTentacleClock(with: timecode, at: now)
        }

        appendTentacleSample(timecode: timecode, localUptime: now)
        updateTentacleClockModelIfNeeded(localUptime: now, force: needsHardReset)
        refreshTentacleClock()
    }

    private func resetTentacleClockModel() {
        tentacleClockModel = nil
        tentacleSyncSamples.removeAll(keepingCapacity: true)
        tentacleRolloverOffsetFrames = 0
        lastTentacleUnwrappedFrame = nil
        lastTentacleModelFitUptime = 0
        tentacleClockAnchor = nil
        lastPublishedTentacleFrameOfDay = nil
    }

    private func appendTentacleSample(timecode: TentacleTimecode, localUptime: TimeInterval) {
        let fps = timecode.fps
        let framesPerDay = max(1, 24 * 60 * 60 * fps)
        let remoteFrames = timecode.totalFramesOfDay
        let unwrappedFrames: Int

        if let previous = lastTentacleUnwrappedFrame {
            var offset = tentacleRolloverOffsetFrames
            var candidate = remoteFrames + offset

            if candidate < previous - framesPerDay / 2 {
                offset += framesPerDay
                candidate = remoteFrames + offset
            } else if candidate > previous + framesPerDay / 2 {
                offset -= framesPerDay
                candidate = remoteFrames + offset
            }

            tentacleRolloverOffsetFrames = offset
            unwrappedFrames = candidate
        } else {
            tentacleRolloverOffsetFrames = 0
            unwrappedFrames = remoteFrames
        }

        lastTentacleUnwrappedFrame = unwrappedFrames
        tentacleSyncSamples.append(TentacleSyncSample(localUptime: localUptime,
                                                      remoteFramesOfDay: remoteFrames,
                                                      unwrappedRemoteFrames: unwrappedFrames,
                                                      fps: fps))

        if tentacleSyncSamples.count > TentacleSyncConfiguration.maxSamples {
            let overflow = tentacleSyncSamples.count - TentacleSyncConfiguration.maxSamples
            tentacleSyncSamples.removeFirst(overflow)
        }
    }

    private func updateTentacleClockModelIfNeeded(localUptime: TimeInterval, force: Bool) {
        guard tentacleSyncSamples.count >= TentacleSyncConfiguration.minSamplesForFit else { return }
        if !force && (localUptime - lastTentacleModelFitUptime) < TentacleSyncConfiguration.fitIntervalSeconds {
            return
        }
        lastTentacleModelFitUptime = localUptime

        let recentSamples = Array(tentacleSyncSamples.suffix(TentacleSyncConfiguration.maxSamples / 2))
        guard let newModel = robustTentacleFit(samples: recentSamples) else { return }

        guard let oldModel = tentacleClockModel, oldModel.fps == newModel.fps else {
            tentacleClockModel = newModel
            return
        }

        let oldFramesNow = oldModel.predictUnwrappedFrames(at: localUptime)
        let newFramesNow = newModel.predictUnwrappedFrames(at: localUptime)
        let diffMS = ((newFramesNow - oldFramesNow) / Double(oldModel.fps)) * 1000.0

        if abs(diffMS) > TentacleSyncConfiguration.hardReplaceThresholdMS {
            tentacleClockModel = newModel
        } else {
            tentacleClockModel = blendTentacleClockModel(old: oldModel,
                                                         new: newModel,
                                                         alpha: TentacleSyncConfiguration.blendAlpha)
        }
    }

    private func robustTentacleFit(samples: [TentacleSyncSample]) -> TentacleClockModel? {
        guard samples.count >= 2 else { return nil }
        let orderedSamples = samples.sorted(by: { $0.localUptime < $1.localUptime })
        guard var model = fitTentacleLinearModel(samples: orderedSamples) else { return nil }

        let errorsMS = residualsMS(model: model, samples: orderedSamples)
        let thresholdMS = max(1.5, 3.0 * median(errorsMS.map { abs($0) }))
        let filteredSamples = zip(orderedSamples, errorsMS)
            .compactMap { sample, errorMS in
                abs(errorMS) <= thresholdMS ? sample : nil
            }

        if filteredSamples.count >= 4, let refined = fitTentacleLinearModel(samples: filteredSamples) {
            model = refined
        }

        return model
    }

    private func fitTentacleLinearModel(samples: [TentacleSyncSample]) -> TentacleClockModel? {
        guard samples.count >= 2 else { return nil }
        let fps = samples[0].fps
        guard samples.allSatisfy({ $0.fps == fps }) else { return nil }

        guard let firstUptime = samples.first?.localUptime,
              let lastUptime = samples.last?.localUptime,
              (lastUptime - firstUptime) > 0.05 else {
            return nil
        }

        let xs = samples.map(\.localUptime)
        let ys = samples.map { Double($0.unwrappedRemoteFrames) }

        let xMean = xs.reduce(0, +) / Double(xs.count)
        let yMean = ys.reduce(0, +) / Double(ys.count)

        let denom = zip(xs, ys).reduce(0.0) { partial, pair in
            let dx = pair.0 - xMean
            return partial + (dx * dx)
        }
        guard denom > 0 else { return nil }

        let numer = zip(xs, ys).reduce(0.0) { partial, pair in
            let dx = pair.0 - xMean
            let dy = pair.1 - yMean
            return partial + (dx * dy)
        }

        var slope = numer / denom
        if !slope.isFinite {
            return nil
        }

        let idealSlope = Double(fps)
        if slope < idealSlope * 0.5 || slope > idealSlope * 1.5 {
            slope = idealSlope
        }

        let intercept = yMean - (slope * xMean)
        return TentacleClockModel(fps: fps, slopeFramesPerSecond: slope, interceptFrames: intercept)
    }

    private func residualsMS(model: TentacleClockModel, samples: [TentacleSyncSample]) -> [Double] {
        samples.map { sample in
            let predicted = model.predictUnwrappedFrames(at: sample.localUptime)
            let errorFrames = predicted - Double(sample.unwrappedRemoteFrames)
            return (errorFrames / Double(sample.fps)) * 1000.0
        }
    }

    private func blendTentacleClockModel(old: TentacleClockModel,
                                         new: TentacleClockModel,
                                         alpha: Double) -> TentacleClockModel {
        guard old.fps == new.fps else { return new }
        let clampedAlpha = min(max(alpha, 0), 1)
        let slope = ((1.0 - clampedAlpha) * old.slopeFramesPerSecond) + (clampedAlpha * new.slopeFramesPerSecond)
        let intercept = ((1.0 - clampedAlpha) * old.interceptFrames) + (clampedAlpha * new.interceptFrames)
        return TentacleClockModel(fps: old.fps, slopeFramesPerSecond: slope, interceptFrames: intercept)
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private func timecodeFrom(totalFramesOfDay: Int, fps: Int) -> TentacleTimecode? {
        guard fps > 0 else { return nil }
        let framesPerDay = 24 * 60 * 60 * fps
        let normalizedFrames = ((totalFramesOfDay % framesPerDay) + framesPerDay) % framesPerDay
        let hours = normalizedFrames / (3600 * fps)
        let minuteRemainder = normalizedFrames % (3600 * fps)
        let minutes = minuteRemainder / (60 * fps)
        let secondRemainder = minuteRemainder % (60 * fps)
        let seconds = secondRemainder / fps
        let frames = secondRemainder % fps
        return TentacleTimecode(fps: fps, hours: hours, minutes: minutes, seconds: seconds, frames: frames)
    }
    
    // MARK: - Starting the camera
    /// Start the camera and begin the stream of data.
    func start() async {
        // Verify that the person authorizes the app to use device cameras and microphones.
        guard await captureService.isAuthorized else {
            status = .unauthorized
            return
        }
        do {
            // Synchronize the state of the model with the persistent state.
            await syncState()
            // Start the capture service to start the flow of data.
            try await captureService.start(with: cameraState)
            if !hasAttachedStateObservers {
                observeState()
                hasAttachedStateObservers = true
            }
            status = .running
            localVideoURLs = await localVideoStore.loadStoredVideos()
            await applyManualControlStateToDevice()
            tentacleTimecodeService.start()
            remoteDirectorClient.start()
        } catch {
            logger.error("Failed to start capture service. \(error)")
            status = .failed
        }
    }

    func stop() async {
        if captureActivity.isRecording {
            await toggleRecording()
        }

        await captureService.stop()
        tentacleTimecodeService.stop()
        remoteDirectorClient.stop()
        stopRecordingClock()
        displayedTentacleTimecode = ""
        displayedTentacleFPS = nil

        if status == .running || status == .interrupted {
            status = .unknown
        }
    }
    
    /// Synchronizes the persistent camera state.
    ///
    /// `CameraState` represents the persistent state, such as the capture mode, that the app and extension share.
    func syncState() async {
        cameraState = await CameraState.current
        cameraState.captureMode = .video
        isApplyingCaptureModeInternally = true
        captureMode = .video
        isApplyingCaptureModeInternally = false
        qualityPrioritization = cameraState.qualityPrioritization
        isLivePhotoEnabled = cameraState.isLivePhotoEnabled
        isHDRVideoEnabled = cameraState.isVideoHDREnabled
    }

    func refreshLocalVideos() async {
        localVideoURLs = await localVideoStore.loadStoredVideos()
    }

    func deleteLocalVideo(_ url: URL) async {
        localVideoURLs = await localVideoStore.delete(urls: [url])
    }

    func deleteLocalVideos(at offsets: IndexSet) async {
        let urlsToDelete: [URL] = offsets.compactMap { index -> URL? in
            guard localVideoURLs.indices.contains(index) else { return nil }
            return localVideoURLs[index]
        }
        localVideoURLs = await localVideoStore.delete(urls: urlsToDelete)
    }
    
    // MARK: - Changing modes and devices
    
    /// A value that indicates the mode of capture for the camera.
    var captureMode = CaptureMode.video {
        didSet {
            if captureMode != .video {
                isApplyingCaptureModeInternally = true
                captureMode = .video
                isApplyingCaptureModeInternally = false
                cameraState.captureMode = .video
                return
            }
            guard status == .running, !isApplyingCaptureModeInternally else { return }
            Task {
                isSwitchingModes = true
                defer { isSwitchingModes = false }
                // Update the configuration of the capture service for the new mode.
                try? await captureService.setCaptureMode(captureMode)
                // Update the persistent state value.
                cameraState.captureMode = .video
                await applyManualControlStateToDevice()
                remoteDirectorClient.sendStatusNow()
            }
        }
    }
    
    /// Selects the next available video device for capture.
    func switchVideoDevices() async {
        isSwitchingVideoDevices = true
        defer { isSwitchingVideoDevices = false }
        await captureService.selectNextVideoDevice()
        await applyManualControlStateToDevice()
    }
    
    // MARK: - Photo capture
    
    /// Captures a photo and writes it to the user's Photos library.
    func capturePhoto() async {
        do {
            let photoFeatures = PhotoFeatures(isLivePhotoEnabled: isLivePhotoEnabled, qualityPrioritization: qualityPrioritization)
            let photo = try await captureService.capturePhoto(with: photoFeatures)
            try await mediaLibrary.save(photo: photo)
        } catch {
            self.error = error
        }
    }
    
    /// A Boolean value that indicates whether to capture Live Photos when capturing stills.
    var isLivePhotoEnabled = true {
        didSet {
            // Update the persistent state value.
            cameraState.isLivePhotoEnabled = isLivePhotoEnabled
        }
    }
    
    /// A value that indicates how to balance the photo capture quality versus speed.
    var qualityPrioritization = QualityPrioritization.quality {
        didSet {
            // Update the persistent state value.
            cameraState.qualityPrioritization = qualityPrioritization
        }
    }
    
    /// Performs a focus and expose operation at the specified screen point.
    func focusAndExpose(at point: CGPoint) async {
        if manualControlState.isFocusLocked {
            return
        }
        let adjustExposure = !manualControlState.hasAnyExposureLock
        await captureService.focusAndExpose(at: point, adjustExposure: adjustExposure)
    }
    
    /// Sets the `showCaptureFeedback` state to indicate that capture is underway.
    private func flashScreen() {
        shouldFlashScreen = true
        withAnimation(.linear(duration: 0.01)) {
            shouldFlashScreen = false
        }
    }
    
    // MARK: - Video capture
    /// A Boolean value that indicates whether the camera captures video in HDR format.
    var isHDRVideoEnabled = false {
        didSet {
            guard status == .running, captureMode == .video else { return }
            Task {
                await captureService.setHDRVideoEnabled(isHDRVideoEnabled)
                // Update the persistent state value.
                cameraState.isVideoHDREnabled = isHDRVideoEnabled
            }
        }
    }
    
    /// Toggles the state of recording.
    func toggleRecording() async {
        switch await captureService.captureActivity {
        case .movieCapture:
            let calibrationJSON = pendingRecordingCalibrationJSON
            pendingRecordingCalibrationJSON = nil
            do {
                // If currently recording, stop and persist the movie to local app storage.
                let movie = try await captureService.stopRecording()
                _ = try await localVideoStore.store(movie: movie, calibrationJSON: calibrationJSON)
                localVideoURLs = await localVideoStore.loadStoredVideos()
                recordingStartTimecodeMetadata = nil
                stopRecordingClock()
            } catch {
                logger.error("Failed to persist local video: \(error.localizedDescription, privacy: .public)")
                self.error = error
            }
        default:
            // In any other case, start recording.
            let recordingSeedTimecode = currentTentacleTimecode()
            recordingStartTimecodeMetadata = currentRecordingStartMetadata()
            pendingRecordingCalibrationJSON = await captureService.recordingCalibrationJSONData()
            startRecordingClock(seedTimecode: recordingSeedTimecode)
            await captureService.startRecording(recordingStartMetadata: recordingStartTimecodeMetadata)
        }
    }
    
    // MARK: - Internal state observations
    
    // Set up camera's state observations.
    private func observeState() {
        Task {
            // Await new thumbnails that the media library generates when saving a file.
            for await thumbnail in mediaLibrary.thumbnails.compactMap({ $0 }) {
                self.thumbnail = thumbnail
            }
        }
        
        Task {
            // Await new capture activity values from the capture service.
            for await activity in await captureService.$captureActivity.values {
                if activity.willCapture {
                    // Flash the screen to indicate capture is starting.
                    flashScreen()
                } else {
                    // Forward the activity to the UI.
                    captureActivity = activity
                    if !activity.isRecording, recordingClockAnchor != nil {
                        stopRecordingClock()
                    }
                    remoteDirectorClient.sendStatusNow()
                }
            }
        }
        
        Task {
            // Await updates to the capabilities that the capture service advertises.
            for await capabilities in await captureService.$captureCapabilities.values {
                isHDRVideoSupported = capabilities.isHDRSupported
                cameraState.isVideoHDRSupported = capabilities.isHDRSupported
                await applyManualControlStateToDevice()
            }
        }
        
        Task {
            // Await updates to a person's interaction with the Camera Control HUD.
            for await isShowingFullscreenControls in await captureService.$isShowingFullscreenControls.values {
                withAnimation {
                    // Prefer showing a minimized UI when capture controls enter a fullscreen appearance.
                    prefersMinimizedUI = isShowingFullscreenControls
                }
            }
        }
    }

    private struct PreparedRemoteStart {
        let sessionID: String
        let startAtUnixMS: Int64
    }

    private func remoteStatusPayload() -> RemoteDirectorStatusPayload {
        let storageGB = FileManager.default.availableStorageGB
        let currentTimecode = currentTentacleTimecode()
        return RemoteDirectorStatusPayload(
            recording: captureActivity.isRecording,
            armed: isRemoteArmed,
            battery: UIDevice.current.batteryLevelNormalized,
            storageGB: storageGB,
            tentacleState: tentacleConnectionState.remoteControlValue,
            timecode: currentTimecode?.formatted ?? displayedTentacleTimecode,
            fps: currentTimecode?.fps ?? displayedTentacleFPS
        )
    }

    private func handleRemoteDirectorCommand(_ command: RemoteDirectorCommandEnvelope) async -> RemoteDirectorCommandReply {
        switch command.command {
        case .arm:
            isRemoteArmed = true
            return .success("Armed.")

        case .prepareStart(let sessionID, let startAtUnixMS):
            pendingRemoteStart = PreparedRemoteStart(sessionID: sessionID, startAtUnixMS: startAtUnixMS)
            isRemoteArmed = true
            return .success("Prepared start for session \(sessionID).")

        case .commitStart(let sessionID, let startAtUnixMS):
            guard let prepared = pendingRemoteStart, prepared.sessionID == sessionID else {
                return .failure("Missing matching prepare_start for session \(sessionID).")
            }

            let targetUnixMS = max(prepared.startAtUnixMS, startAtUnixMS)
            remoteStartTask?.cancel()
            remoteStartTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.waitUntil(unixMilliseconds: targetUnixMS)
                guard !Task.isCancelled else { return }
                await self.performRemoteStart()
                self.pendingRemoteStart = nil
                self.remoteDirectorClient.sendStatusNow()
            }
            return .success("Commit accepted for session \(sessionID).")

        case .prepareStop(_, let stopAtUnixMS):
            remoteStopTask?.cancel()
            remoteStopTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.waitUntil(unixMilliseconds: stopAtUnixMS)
                guard !Task.isCancelled else { return }
                await self.performRemoteStop()
                self.remoteDirectorClient.sendStatusNow()
            }
            return .success("Prepared stop.")
        }
    }

    private func waitUntil(unixMilliseconds: Int64) async {
        let nowMS = Int64(Date().timeIntervalSince1970 * 1000)
        let delayMS = max(0, unixMilliseconds - nowMS)
        if delayMS > 0 {
            let delayNS = UInt64(delayMS) * 1_000_000
            try? await Task.sleep(nanoseconds: delayNS)
        }
    }

    private func performRemoteStart() async {
        guard status == .running else { return }
        do {
            try await setCaptureModeDirectly(.video)
            if !captureActivity.isRecording {
                await toggleRecording()
            }
            isRemoteArmed = false
        } catch {
            self.error = error
        }
    }

    private func performRemoteStop() async {
        guard status == .running else { return }
        if captureActivity.isRecording {
            await toggleRecording()
        }
        isRemoteArmed = false
    }

    private func setCaptureModeDirectly(_ mode: CaptureMode) async throws {
        guard mode == .video else { return }
        guard captureMode != mode else { return }

        isSwitchingModes = true
        defer { isSwitchingModes = false }

        try await captureService.setCaptureMode(mode)
        isApplyingCaptureModeInternally = true
        captureMode = mode
        isApplyingCaptureModeInternally = false
        cameraState.captureMode = mode
        await applyManualControlStateToDevice()
    }
}

private struct RemoteDirectorStatusPayload {
    let recording: Bool
    let armed: Bool
    let battery: Double?
    let storageGB: Double?
    let tentacleState: String
    let timecode: String
    let fps: Int?

    static let empty = RemoteDirectorStatusPayload(recording: false,
                                                   armed: false,
                                                   battery: nil,
                                                   storageGB: nil,
                                                   tentacleState: "unknown",
                                                   timecode: "",
                                                   fps: nil)
}

private enum RemoteDirectorCommand {
    case arm
    case prepareStart(sessionID: String, startAtUnixMS: Int64)
    case commitStart(sessionID: String, startAtUnixMS: Int64)
    case prepareStop(sessionID: String, stopAtUnixMS: Int64)
}

private struct RemoteDirectorCommandEnvelope {
    let requestID: String
    let command: RemoteDirectorCommand
}

private struct RemoteDirectorCommandReply {
    let ok: Bool
    let detail: String

    static func success(_ detail: String) -> RemoteDirectorCommandReply {
        .init(ok: true, detail: detail)
    }

    static func failure(_ detail: String) -> RemoteDirectorCommandReply {
        .init(ok: false, detail: detail)
    }
}

@MainActor
private final class RemoteDirectorClient {

    typealias StatusProvider = () -> RemoteDirectorStatusPayload
    typealias CommandHandler = (RemoteDirectorCommandEnvelope) async -> RemoteDirectorCommandReply

    private static let deviceIDDefaultsKey = "RemoteDirectorDeviceID"
    private static let reconnectDelayMS: UInt64 = 2_000
    private static let statusIntervalMS: UInt64 = 1_000
    private static let burstStatusDebounceMS: UInt64 = 150

    var statusProvider: StatusProvider?
    var commandHandler: CommandHandler?
    var deviceNameProvider: (() -> String)?

    private let session = URLSession(configuration: .default)
    private let deviceID: String
    private let appVersion: String

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var pendingBurstStatusTask: Task<Void, Never>?
    private var shouldRun = false
    private var isConnecting = false

    init() {
        deviceID = Self.loadOrCreateDeviceID()
        appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    func start() {
        guard !shouldRun else { return }
        guard directorURL() != nil else {
            logger.info("Remote director disabled. Set UserDefaults key \(RemoteDirectorConfiguration.directorWebSocketURLDefaultsKey, privacy: .public) to ws://<host>:8765.")
            return
        }
        shouldRun = true
        connectIfNeeded()
    }

    func stop() {
        shouldRun = false
        reconnectTask?.cancel()
        receiveTask?.cancel()
        statusTask?.cancel()
        pendingBurstStatusTask?.cancel()
        reconnectTask = nil
        receiveTask = nil
        statusTask = nil
        pendingBurstStatusTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnecting = false
    }

    func sendStatusNow() {
        Task { @MainActor in
            await sendStatus()
        }
    }

    func sendStatusSoon() {
        guard shouldRun else { return }
        guard pendingBurstStatusTask == nil else { return }

        pendingBurstStatusTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: Self.burstStatusDebounceMS * 1_000_000)
            guard !Task.isCancelled else { return }
            self.pendingBurstStatusTask = nil
            await self.sendStatus()
        }
    }

    private func connectIfNeeded() {
        guard shouldRun else { return }
        guard !isConnecting, webSocketTask == nil else { return }
        guard let url = directorURL() else { return }

        isConnecting = true
        let task = session.webSocketTask(with: url)
        webSocketTask = task
        task.resume()
        isConnecting = false

        logger.info("Connected to remote director \(url.absoluteString, privacy: .public)")

        receiveTask?.cancel()
        statusTask?.cancel()
        receiveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.receiveLoop()
        }
        statusTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.statusLoop()
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sendHello()
            await self.sendStatus()
        }
    }

    private func receiveLoop() async {
        guard let task = webSocketTask else { return }

        do {
            while shouldRun {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    await handleInboundText(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        await handleInboundText(text)
                    }
                @unknown default:
                    break
                }
            }
        } catch {
            logger.error("Remote director receive loop failed: \(error.localizedDescription, privacy: .public)")
        }

        handleDisconnectAndReconnect()
    }

    private func statusLoop() async {
        while shouldRun {
            try? await Task.sleep(nanoseconds: Self.statusIntervalMS * 1_000_000)
            if Task.isCancelled { return }
            await sendStatus()
        }
    }

    private func handleDisconnectAndReconnect() {
        receiveTask?.cancel()
        statusTask?.cancel()
        pendingBurstStatusTask?.cancel()
        receiveTask = nil
        statusTask = nil
        pendingBurstStatusTask = nil
        webSocketTask = nil
        isConnecting = false

        guard shouldRun else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: Self.reconnectDelayMS * 1_000_000)
            guard !Task.isCancelled else { return }
            self.connectIfNeeded()
        }
    }

    private func sendHello() async {
        let message: [String: Any] = [
            "type": "hello",
            "device_id": deviceID,
            "name": resolvedDeviceName(),
            "app_version": appVersion
        ]
        await sendJSONObject(message)
    }

    private func sendStatus() async {
        guard let statusProvider else { return }
        let status = statusProvider()

        var message: [String: Any] = [
            "type": "status",
            "device_id": deviceID,
            "name": resolvedDeviceName(),
            "recording": status.recording,
            "armed": status.armed,
            "tentacle_state": status.tentacleState,
            "timecode": status.timecode
        ]

        if let battery = status.battery {
            message["battery"] = battery
        }
        if let storageGB = status.storageGB {
            message["storage_gb"] = storageGB
        }
        if let fps = status.fps {
            message["fps"] = fps
        }

        await sendJSONObject(message)
    }

    private func handleInboundText(_ text: String) async {
        guard let data = text.data(using: .utf8) else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any] else {
            logger.error("Invalid remote director payload.")
            return
        }

        guard let type = payload["type"] as? String, type == "command" else {
            return
        }
        guard let commandName = payload["command"] as? String else {
            return
        }
        let requestID = payload["request_id"] as? String ?? UUID().uuidString

        if commandName == "ping" {
            await sendJSONObject([
                "type": "pong",
                "device_id": deviceID,
                "request_id": requestID
            ])
            return
        }

        guard let envelope = parseCommandEnvelope(commandName: commandName,
                                                  payload: payload,
                                                  requestID: requestID) else {
            await sendAck(requestID: requestID, reply: .failure("Invalid command payload."))
            return
        }

        guard let commandHandler else {
            await sendAck(requestID: requestID, reply: .failure("Command handler unavailable."))
            return
        }

        let reply = await commandHandler(envelope)
        await sendAck(requestID: requestID, reply: reply)
        await sendStatus()
    }

    private func parseCommandEnvelope(commandName: String,
                                      payload: [String: Any],
                                      requestID: String) -> RemoteDirectorCommandEnvelope? {
        let command: RemoteDirectorCommand
        switch commandName {
        case "arm":
            command = .arm
        case "prepare_start":
            guard let sessionID = payload["session_id"] as? String,
                  let startAtUnixMS = int64Value(payload["start_at_unix_ms"]) else { return nil }
            command = .prepareStart(sessionID: sessionID, startAtUnixMS: startAtUnixMS)
        case "commit_start":
            guard let sessionID = payload["session_id"] as? String,
                  let startAtUnixMS = int64Value(payload["start_at_unix_ms"]) else { return nil }
            command = .commitStart(sessionID: sessionID, startAtUnixMS: startAtUnixMS)
        case "prepare_stop":
            let sessionID = payload["session_id"] as? String ?? "unknown-session"
            guard let stopAtUnixMS = int64Value(payload["stop_at_unix_ms"]) else { return nil }
            command = .prepareStop(sessionID: sessionID, stopAtUnixMS: stopAtUnixMS)
        default:
            return nil
        }

        return RemoteDirectorCommandEnvelope(requestID: requestID, command: command)
    }

    private func sendAck(requestID: String, reply: RemoteDirectorCommandReply) async {
        await sendJSONObject([
            "type": "ack",
            "device_id": deviceID,
            "request_id": requestID,
            "ok": reply.ok,
            "detail": reply.detail
        ])
    }

    private func sendJSONObject(_ object: [String: Any]) async {
        guard let webSocketTask else { return }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            logger.error("Unable to encode remote director payload.")
            return
        }

        do {
            try await webSocketTask.send(.string(text))
        } catch {
            logger.error("Unable to send remote director payload: \(error.localizedDescription, privacy: .public)")
            handleDisconnectAndReconnect()
        }
    }

    private func directorURL() -> URL? {
        // Disable remote control in extensions; run only in the app.
        guard Bundle.main.bundleURL.pathExtension != "appex" else { return nil }

        if let defaultsURL = UserDefaults.standard.string(forKey: RemoteDirectorConfiguration.directorWebSocketURLDefaultsKey),
           !defaultsURL.isEmpty,
           let url = URL(string: defaultsURL) {
            return url
        }

        if let environmentURL = ProcessInfo.processInfo.environment["DIRECTOR_WS_URL"],
           !environmentURL.isEmpty,
           let url = URL(string: environmentURL) {
            return url
        }

        if let infoURL = Bundle.main.object(forInfoDictionaryKey: RemoteDirectorConfiguration.directorWebSocketURLInfoKey) as? String,
           !infoURL.isEmpty,
           let url = URL(string: infoURL) {
            return url
        }

        return nil
    }

    private static func loadOrCreateDeviceID() -> String {
        if let existing = UserDefaults.standard.string(forKey: deviceIDDefaultsKey), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: deviceIDDefaultsKey)
        return generated
    }

    private func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 {
            return value
        }
        if let value = value as? Int {
            return Int64(value)
        }
        if let value = value as? Double {
            return Int64(value)
        }
        if let value = value as? NSNumber {
            return value.int64Value
        }
        return nil
    }

    private func resolvedDeviceName() -> String {
        let candidate = deviceNameProvider?().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return candidate.isEmpty ? UIDevice.current.name : candidate
    }
}

private extension UIDevice {
    var batteryLevelNormalized: Double? {
        let level = batteryLevel
        guard level >= 0 else { return nil }
        return Double(level)
    }
}

private extension FileManager {
    var availableStorageGB: Double? {
        do {
            let values = try URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let bytes = values.volumeAvailableCapacityForImportantUsage {
                return Double(bytes) / 1_000_000_000.0
            }
        } catch {
            return nil
        }
        return nil
    }
}

private actor LocalVideoStore {

    private static let folderName = "Videos"
    private static let storedRelativePathsDefaultsKey = "LocalVideoRelativePaths"
    private static let finalizeRetryCount = 40
    private static let finalizeRetryDelayNS: UInt64 = 75_000_000
    private static let relocationRetryCount = 20
    private static let relocationRetryDelayNS: UInt64 = 100_000_000

    private let fileManager = FileManager.default

    func loadStoredVideos() -> [URL] {
        guard let folderURL = try? ensureVideosFolder() else { return [] }

        let storedRelativePaths = UserDefaults.standard.stringArray(forKey: Self.storedRelativePathsDefaultsKey) ?? []
        let restoredFromDefaults = storedRelativePaths
            .map { folderURL.appending(path: $0, directoryHint: .notDirectory) }
            .filter { fileManager.fileExists(atPath: $0.path()) }
        let discoveredInFolder = listVideosInFolder(folderURL)
        let restoredURLs = deduplicatedURLs(restoredFromDefaults + discoveredInFolder)

        persistVideoList(restoredURLs)
        return restoredURLs
    }

    func store(movie: Movie, calibrationJSON: Data?) async throws -> URL {
        try await waitForMovieFileToExist(at: movie.url)
        let folderURL = try ensureVideosFolder()
        let sourceFolderURL = movie.url.deletingLastPathComponent()

        let destinationURL: URL
        if isSameFileLocation(sourceFolderURL, folderURL) {
            destinationURL = movie.url
        } else {
            let relocatedURL = folderURL.appending(path: uniqueFileName(), directoryHint: .notDirectory)
            try await moveOrCopyMovie(from: movie.url, to: relocatedURL)
            destinationURL = relocatedURL
        }

        if let calibrationJSON {
            try writeCalibrationSidecar(calibrationJSON, forMovieURL: destinationURL)
        }
        markExcludedFromBackupIfPossible(destinationURL)
        markExcludedFromBackupIfPossible(calibrationSidecarURL(forMovieURL: destinationURL))

        var urls = loadStoredVideos()
        let destinationPath = canonicalPath(for: destinationURL)
        urls.removeAll { canonicalPath(for: $0) == destinationPath }
        urls.insert(destinationURL, at: 0)
        persistVideoList(urls)
        return destinationURL
    }

    func delete(urls: [URL]) -> [URL] {
        guard !urls.isEmpty else {
            return loadStoredVideos()
        }

        let pathsToDelete = Set(urls.map { canonicalPath(for: $0) })
        for url in urls where fileManager.fileExists(atPath: canonicalPath(for: url)) {
            try? fileManager.removeItem(at: url)
            let sidecarURL = calibrationSidecarURL(forMovieURL: url)
            if fileManager.fileExists(atPath: sidecarURL.path) {
                try? fileManager.removeItem(at: sidecarURL)
            }
        }

        var remaining = loadStoredVideos()
        remaining.removeAll { pathsToDelete.contains(canonicalPath(for: $0)) }
        persistVideoList(remaining)
        return remaining
    }

    private func ensureVideosFolder() throws -> URL {
        let videosURL = preferredVideosFolderURL()
        if !fileManager.fileExists(atPath: videosURL.path) {
            do {
                try fileManager.createDirectory(at: videosURL, withIntermediateDirectories: true)
            } catch {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        markExcludedFromBackupIfPossible(videosURL)
        migrateLegacyVideosIfNeeded(to: videosURL)
        return videosURL
    }

    private func preferredVideosFolderURL() -> URL {
        if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            return documentsURL.appendingPathComponent(Self.folderName, isDirectory: true)
        }
        if let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return appSupportURL.appendingPathComponent(Self.folderName, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(Self.folderName, isDirectory: true)
    }

    private func legacyVideosFolderURL(relativeTo preferredURL: URL) -> URL? {
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let legacyURL = appSupportURL.appendingPathComponent(Self.folderName, isDirectory: true)
        guard !isSameFileLocation(legacyURL, preferredURL) else {
            return nil
        }
        return legacyURL
    }

    private func migrateLegacyVideosIfNeeded(to preferredURL: URL) {
        guard let legacyURL = legacyVideosFolderURL(relativeTo: preferredURL),
              fileManager.fileExists(atPath: legacyURL.path),
              let contents = try? fileManager.contentsOfDirectory(at: legacyURL,
                                                                  includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles]) else {
            return
        }

        for sourceURL in contents where shouldMigrateFile(at: sourceURL) {
            let destinationURL = preferredURL.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: false)
            if fileManager.fileExists(atPath: destinationURL.path) {
                continue
            }

            do {
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
            } catch {
                do {
                    try fileManager.copyItem(at: sourceURL, to: destinationURL)
                    try? fileManager.removeItem(at: sourceURL)
                } catch {
                    logger.error("Failed to migrate local video file \(sourceURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            markExcludedFromBackupIfPossible(destinationURL)
        }

        if let remaining = try? fileManager.contentsOfDirectory(at: legacyURL,
                                                                includingPropertiesForKeys: nil,
                                                                options: [.skipsHiddenFiles]),
           remaining.isEmpty {
            try? fileManager.removeItem(at: legacyURL)
        }
    }

    private func shouldMigrateFile(at url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "mov" || ext == "mp4" || ext == "json"
    }

    private func uniqueFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let timestamp = formatter.string(from: Date())
        return "video_\(timestamp)_\(UUID().uuidString.prefix(8)).mov"
    }

    private func calibrationSidecarURL(forMovieURL movieURL: URL) -> URL {
        movieURL.deletingPathExtension().appendingPathExtension("json")
    }

    private func writeCalibrationSidecar(_ calibrationJSON: Data, forMovieURL movieURL: URL) throws {
        let sidecarURL = calibrationSidecarURL(forMovieURL: movieURL)
        if fileManager.fileExists(atPath: sidecarURL.path) {
            try fileManager.removeItem(at: sidecarURL)
        }
        try calibrationJSON.write(to: sidecarURL, options: [.atomic])
    }

    private func markExcludedFromBackupIfPossible(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    private func listVideosInFolder(_ folderURL: URL) -> [URL] {
        guard let urls = try? fileManager.contentsOfDirectory(at: folderURL,
                                                              includingPropertiesForKeys: [.contentModificationDateKey],
                                                              options: [.skipsHiddenFiles]) else {
            return []
        }

        return urls
            .filter { $0.pathExtension.lowercased() == "mov" || $0.pathExtension.lowercased() == "mp4" }
            .sorted(by: isOrderedMostRecentFirst(_:_:))
    }

    private func isOrderedMostRecentFirst(_ lhs: URL, _ rhs: URL) -> Bool {
        let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return lhsDate > rhsDate
    }

    private func persistVideoList(_ urls: [URL]) {
        let relativePaths = urls.map(\.lastPathComponent)
        UserDefaults.standard.set(relativePaths, forKey: Self.storedRelativePathsDefaultsKey)
    }

    private func deduplicatedURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var unique = [URL]()

        for url in urls.sorted(by: isOrderedMostRecentFirst(_:_:)) {
            let key = canonicalPath(for: url)
            if seen.insert(key).inserted {
                unique.append(url)
            }
        }
        return unique
    }

    private func canonicalPath(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func isSameFileLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        canonicalPath(for: lhs) == canonicalPath(for: rhs)
    }

    private func waitForMovieFileToExist(at url: URL) async throws {
        if fileManager.fileExists(atPath: url.path) {
            return
        }

        for _ in 0..<Self.finalizeRetryCount {
            try await Task.sleep(nanoseconds: Self.finalizeRetryDelayNS)
            if fileManager.fileExists(atPath: url.path) {
                return
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func moveOrCopyMovie(from sourceURL: URL, to destinationURL: URL) async throws {
        for attempt in 0..<Self.relocationRetryCount {
            do {
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
                return
            } catch {
                do {
                    try fileManager.copyItem(at: sourceURL, to: destinationURL)
                    try? fileManager.removeItem(at: sourceURL)
                    return
                } catch {
                    try? fileManager.removeItem(at: destinationURL)
                    if attempt + 1 == Self.relocationRetryCount {
                        throw error
                    }
                    try await Task.sleep(nanoseconds: Self.relocationRetryDelayNS)
                }
            }
        }
        throw CocoaError(.fileWriteUnknown)
    }
}

private final class TentacleTimecodeService: NSObject {

    var onUpdate: ((TentacleConnectionState, TentacleTimecode?) -> Void)?

    private let timecodeCharacteristicUUID = CBUUID(string: "0dab144c-2cb9-11e6-b67b-9e71128cae77")
    private let preferredNames = ["neurok", "tentacle", "sync e"]

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var isScanning = false
    private var isStarted = false
    private var pendingServiceUUIDs = Set<CBUUID>()
    private var didFindTimecodeCharacteristic = false

    private var connectionState = TentacleConnectionState.idle {
        didSet {
            guard connectionState != oldValue else { return }
            publish()
        }
    }

    private var latestTimecode: TentacleTimecode? {
        didSet {
            guard latestTimecode != oldValue else { return }
            publish()
        }
    }

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func start() {
        isStarted = true
        handleBluetoothState(centralManager.state)
    }

    func stop() {
        isStarted = false
        stopScan()
        if let connectedPeripheral {
            centralManager.cancelPeripheralConnection(connectedPeripheral)
        }
        connectedPeripheral = nil
        latestTimecode = nil
        connectionState = .idle
    }

    private func handleBluetoothState(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            guard isStarted else { return }
            startScanIfNeeded()
        case .unauthorized:
            connectionState = .unauthorized
        case .unsupported:
            connectionState = .bluetoothUnavailable
        case .poweredOff:
            connectionState = .bluetoothUnavailable
        case .resetting, .unknown:
            connectionState = .idle
        @unknown default:
            connectionState = .idle
        }
    }

    private func startScanIfNeeded(reconnectingDeviceName: String? = nil) {
        guard isStarted, centralManager.state == .poweredOn else { return }
        guard connectedPeripheral == nil else { return }
        guard !isScanning else { return }

        isScanning = true
        centralManager.scanForPeripherals(withServices: nil,
                                          options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])

        if let reconnectingDeviceName {
            connectionState = .reconnecting(reconnectingDeviceName)
        } else {
            connectionState = .scanning
        }
    }

    private func stopScan() {
        guard isScanning else { return }
        centralManager.stopScan()
        isScanning = false
    }

    private func updateConnectedDeviceState(for peripheral: CBPeripheral) {
        connectionState = .connected(deviceName(for: peripheral))
    }

    private func connect(_ peripheral: CBPeripheral) {
        stopScan()
        connectedPeripheral = peripheral
        latestTimecode = nil
        peripheral.delegate = self
        connectionState = .connecting(deviceName(for: peripheral))
        centralManager.connect(peripheral, options: nil)
    }

    private func disconnectAndRescan(with state: TentacleConnectionState, clearTimecode: Bool) {
        if clearTimecode {
            latestTimecode = nil
        }
        connectionState = state
        let reconnectingName = connectedPeripheral.map(deviceName(for:))
        if let connectedPeripheral {
            centralManager.cancelPeripheralConnection(connectedPeripheral)
        }
        connectedPeripheral = nil
        startScanIfNeeded(reconnectingDeviceName: reconnectingName)
    }

    private func decodeTentacleTimecode(_ data: Data) -> TentacleTimecode? {
        TentacleTimecode(payload: data)
    }

    private func shouldUsePeripheral(_ peripheral: CBPeripheral, advertisementName: String?) -> Bool {
        let candidates = [peripheral.name, advertisementName]
            .compactMap { $0?.lowercased() }
        return candidates.contains(where: isPreferredDeviceName(_:))
    }

    private func isPreferredDeviceName(_ name: String) -> Bool {
        preferredNames.contains(where: { name.contains($0) })
    }

    private func deviceName(for peripheral: CBPeripheral) -> String {
        peripheral.name ?? "Tentacle"
    }

    private func publish() {
        onUpdate?(connectionState, latestTimecode)
    }

    private func completeCharacteristicDiscovery(for service: CBService) {
        pendingServiceUUIDs.remove(service.uuid)
        if pendingServiceUUIDs.isEmpty && !didFindTimecodeCharacteristic {
            disconnectAndRescan(with: .failed("Tentacle timecode characteristic not found"),
                                clearTimecode: false)
        }
    }
}

extension TentacleTimecodeService: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        handleBluetoothState(central.state)
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard connectedPeripheral == nil else { return }
        let advertisementName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard shouldUsePeripheral(peripheral, advertisementName: advertisementName) else { return }
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        pendingServiceUUIDs.removeAll()
        didFindTimecodeCharacteristic = false
        updateConnectedDeviceState(for: peripheral)
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: (any Error)?) {
        disconnectAndRescan(with: .failed(error?.localizedDescription ?? "Failed to connect"),
                            clearTimecode: false)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: (any Error)?) {
        let connectionName = deviceName(for: peripheral)
        let nextState: TentacleConnectionState
        if let error {
            nextState = .failed(error.localizedDescription)
        } else {
            nextState = .reconnecting(connectionName)
        }
        connectedPeripheral = nil
        connectionState = nextState
        startScanIfNeeded(reconnectingDeviceName: connectionName)
    }
}

extension TentacleTimecodeService: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        if let error {
            disconnectAndRescan(with: .failed(error.localizedDescription), clearTimecode: false)
            return
        }

        guard let services = peripheral.services, !services.isEmpty else {
            disconnectAndRescan(with: .failed("No GATT services available"), clearTimecode: false)
            return
        }

        pendingServiceUUIDs = Set(services.map(\.uuid))
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: (any Error)?) {
        if let error {
            disconnectAndRescan(with: .failed(error.localizedDescription), clearTimecode: false)
            return
        }

        guard let characteristics = service.characteristics else {
            completeCharacteristicDiscovery(for: service)
            return
        }
        for characteristic in characteristics where characteristic.uuid == timecodeCharacteristicUUID {
            didFindTimecodeCharacteristic = true
            peripheral.setNotifyValue(true, for: characteristic)
            peripheral.readValue(for: characteristic)
        }
        completeCharacteristicDiscovery(for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: (any Error)?) {
        guard characteristic.uuid == timecodeCharacteristicUUID else { return }
        if let error {
            disconnectAndRescan(with: .failed(error.localizedDescription), clearTimecode: false)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: (any Error)?) {
        guard characteristic.uuid == timecodeCharacteristicUUID else { return }
        guard error == nil else {
            if let error {
                disconnectAndRescan(with: .failed(error.localizedDescription), clearTimecode: false)
            }
            return
        }
        guard let data = characteristic.value, let timecode = decodeTentacleTimecode(data) else { return }
        latestTimecode = timecode
    }
}
