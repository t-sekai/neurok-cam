/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A view that displays a thumbnail of the last captured media.
*/

import SwiftUI
import AVKit

/// A view that displays a thumbnail of the last captured media.
///
/// Tapping the view opens locally stored recordings from the app sandbox.
struct ThumbnailButton<CameraModel: Camera>: View {
    
	let camera: CameraModel
    let openLocalVideos: () -> Void
	
    var body: some View {
        Button {
            openLocalVideos()
        } label: {
            thumbnail
        }
        .buttonStyle(.plain)
		.frame(width: 64.0, height: 64.0)
		.cornerRadius(8)
        .disabled(camera.captureActivity.isRecording)
    }
    
    @ViewBuilder
    var thumbnail: some View {
        if let thumbnail = camera.thumbnail {
            Image(thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .animation(.easeInOut(duration: 0.3), value: thumbnail)
        } else if camera.localVideoURLs.isEmpty {
            Image(systemName: "video")
        } else {
            Image(systemName: "film.stack.fill")
        }
    }
}

struct LocalVideosView<CameraModel: Camera>: View {
    let camera: CameraModel

    var body: some View {
        NavigationStack {
            List {
                if camera.localVideoURLs.isEmpty {
                    ContentUnavailableView("No Local Videos",
                                           systemImage: "video.slash",
                                           description: Text("Record a video to see it here."))
                } else {
                    ForEach(camera.localVideoURLs, id: \.self) { url in
                        NavigationLink(value: url) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(url.lastPathComponent)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text(url.deletingLastPathComponent().lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                Task { await camera.deleteLocalVideo(url) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete(perform: deleteVideos)
                }
            }
            .navigationTitle("Local Videos")
            .navigationDestination(for: URL.self) { url in
                LocalVideoPlayerView(url: url)
            }
            .toolbar {
                if !camera.localVideoURLs.isEmpty {
                    EditButton()
                }
            }
            .task {
                await camera.refreshLocalVideos()
            }
            .refreshable {
                await camera.refreshLocalVideos()
            }
        }
    }

    private func deleteVideos(at offsets: IndexSet) {
        Task {
            await camera.deleteLocalVideos(at: offsets)
        }
    }
}

struct LocalVideoPlayerView: View {
    let url: URL
    @State private var player: AVPlayer

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear {
                player.pause()
            }
    }
}
