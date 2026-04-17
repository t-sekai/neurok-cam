/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
An object that manages a movie capture output to record videos.
*/

import AVFoundation
import Combine

/// An object that manages a movie capture output to record videos.
final class MovieCapture: OutputService {
    
    /// A value that indicates the current state of movie capture.
    @Published private(set) var captureActivity: CaptureActivity = .idle
    
    /// The capture output type for this service.
    let output = AVCaptureMovieFileOutput()
    // An internal alias for the output.
    private var movieOutput: AVCaptureMovieFileOutput { output }
    
    // A delegate object to respond to movie capture events.
    private var delegate: MovieCaptureDelegate?
    
    // The interval at which to update the recording time.
    private let refreshInterval = TimeInterval(0.25)
    private var timerCancellable: AnyCancellable?
    
    // A Boolean value that indicates whether the currently selected camera's
    // active format supports HDR.
    private var isHDRSupported = false
    
    // MARK: - Capturing a movie
    
    /// Starts movie recording.
    func startRecording(recordingStartMetadata: RecordingStartTimecodeMetadata?) {
        // Return early if already recording.
        guard !movieOutput.isRecording else { return }
        
        guard let connection = movieOutput.connection(with: .video) else {
            fatalError("Configuration error. No video connection found.")
        }

        // Configure connection for HEVC capture.
        if movieOutput.availableVideoCodecTypes.contains(.hevc) {
            movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
        }

        // Enable video stabilization if the connection supports it.
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .auto
        }

        movieOutput.metadata = metadataItems(for: recordingStartMetadata)
        
        // Start a timer to update the recording time.
        startMonitoringDuration()
        
        delegate = MovieCaptureDelegate()
        movieOutput.startRecording(to: URL.localVideoRecordingFileURL, recordingDelegate: delegate!)
    }
    
    /// Stops movie recording.
    /// - Returns: A `Movie` object that represents the captured movie.
    func stopRecording() async throws -> Movie {
        // Use a continuation to adapt the delegate-based capture API to an async interface.
        return try await withCheckedThrowingContinuation { continuation in
            // Set the continuation on the delegate to handle the capture result.
            delegate?.continuation = continuation
            
            /// Stops recording, which causes the output to call the `MovieCaptureDelegate` object.
            movieOutput.stopRecording()
            stopMonitoringDuration()
        }
    }
    
    // MARK: - Movie capture delegate
    /// A delegate object that responds to the capture output finalizing movie recording.
    private class MovieCaptureDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
        
        var continuation: CheckedContinuation<Movie, Error>?
        
        func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
            let isFinishedSuccessfully: Bool
            if let nsError = error as NSError? {
                let completionKey = AVErrorRecordingSuccessfullyFinishedKey
                isFinishedSuccessfully = (nsError.userInfo[completionKey] as? Bool) ?? false
                if !isFinishedSuccessfully {
                    // Only fail when AVFoundation explicitly indicates the recording didn't finish.
                    continuation?.resume(throwing: nsError)
                    continuation = nil
                    return
                }
            } else {
                isFinishedSuccessfully = true
            }

            guard isFinishedSuccessfully else {
                continuation?.resume(throwing: CocoaError(.fileWriteUnknown))
                continuation = nil
                return
            }

            // Return a new movie object for successful finalization.
            continuation?.resume(returning: Movie(url: outputFileURL))
            continuation = nil
        }
    }
    
    // MARK: - Monitoring recorded duration
    
    // Starts a timer to update the recording time.
    private func startMonitoringDuration() {
        captureActivity = .movieCapture()
        timerCancellable = Timer.publish(every: refreshInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                // Poll the movie output for its recorded duration.
                let duration = movieOutput.recordedDuration.seconds
                captureActivity = .movieCapture(duration: duration)
            }
    }
    
    /// Stops the timer and resets the time to `CMTime.zero`.
    private func stopMonitoringDuration() {
        timerCancellable?.cancel()
        captureActivity = .idle
    }
    
    func updateConfiguration(for device: AVCaptureDevice) {
        // The app supports HDR video capture if the active format supports it.
        isHDRSupported = device.activeFormat10BitVariant != nil
    }

    private func metadataItems(for startMetadata: RecordingStartTimecodeMetadata?) -> [AVMetadataItem] {
        guard let startMetadata else { return [] }

        let source = makeMetadataItem(key: "com.kevin.avcam.timecode_source", value: startMetadata.source)
        let timecode = makeMetadataItem(key: "com.kevin.avcam.start_timecode", value: startMetadata.timecode)
        let fps = makeMetadataItem(key: "com.kevin.avcam.start_fps", value: "\(startMetadata.fps)")
        let description = makeCommonDescriptionItem(value: "Start TC \(startMetadata.timecode) @ \(startMetadata.fps) fps")
        return [source, timecode, fps, description]
    }

    private func makeMetadataItem(key: String, value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = key as NSString
        item.value = value as NSString
        return item
    }

    private func makeCommonDescriptionItem(value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .common
        item.key = AVMetadataKey.commonKeyDescription as NSString
        item.value = value as NSString
        return item
    }

    // MARK: - Configuration
    /// Returns the capabilities for this capture service.
    var capabilities: CaptureCapabilities {
        CaptureCapabilities(isHDRSupported: isHDRSupported)
    }
}
