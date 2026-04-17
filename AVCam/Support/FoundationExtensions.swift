/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Extensions on Foundation types.
*/

import Foundation

extension URL {
    /// A unique output location to write a movie.
    static var movieFileURL: URL {
        URL.temporaryDirectory.appending(component: UUID().uuidString).appendingPathExtension(for: .quickTimeMovie)
    }

    /// A unique output location for persisted local video recordings.
    static var localVideoRecordingFileURL: URL {
        let fileManager = FileManager.default
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL.temporaryDirectory

        let videosURL = baseURL.appendingPathComponent("Videos", isDirectory: true)
        try? fileManager.createDirectory(at: videosURL, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let timestamp = formatter.string(from: Date())
        let fileName = "video_\(timestamp)_\(UUID().uuidString.prefix(8))"
        return videosURL.appending(component: fileName).appendingPathExtension(for: .quickTimeMovie)
    }
}
