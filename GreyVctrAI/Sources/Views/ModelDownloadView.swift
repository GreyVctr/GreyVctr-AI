import SwiftUI

/// View shown when the Gemma 4 E2B model has not been downloaded yet.
///
/// Displays download progress using `ModelDownloader`, with support for
/// pause/resume and file size display. Transitions to engine loading
/// once the download completes.
struct ModelDownloadView: View {
    let downloader: ModelDownloader
    let onDownloadComplete: () -> Void

    @State private var hasStarted = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // App icon / branding
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.app.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.blue)

                Text("GreyVctr AI")
                    .font(.largeTitle.bold())

                Text("Download an AI model that runs locally")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Download status area
            VStack(spacing: 16) {
                switch downloader.status {
                case .notStarted:
                    notStartedSection

                case .downloading(let progress):
                    downloadingSection(progress: progress)

                case .paused:
                    pausedSection

                case .completed:
                    completedSection

                case .failed(let message):
                    failedSection(message: message)
                }
            }
            .padding(.horizontal, 32)

            Spacer()

            // Privacy note
            Text("The model runs entirely on your device. The download can continue if the screen locks.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 16)
        }
    }

    // MARK: - State Sections

    private var notStartedSection: some View {
        VStack(spacing: 16) {
            Text("\(ModelDownloader.currentModel.name) needs to be downloaded before first use.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("Version \(String(ModelDownloader.currentModel.commitHash.prefix(7))) • \(downloader.totalBytesDisplay)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Button {
                Task {
                    hasStarted = true
                    try await downloader.download()
                    await MainActor.run { onDownloadComplete() }
                }
            } label: {
                Label("Download Model", systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func downloadingSection(progress: Double) -> some View {
        VStack(spacing: 12) {
            ProgressView(value: progress) {
                Text("Downloading…")
                    .font(.headline)
            } currentValueLabel: {
                Text("\(Int(progress * 100))%")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button {
                downloader.pause()
            } label: {
                Label("Pause", systemImage: "pause.circle")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
        }
    }

    private var pausedSection: some View {
        VStack(spacing: 12) {
            Text("Download paused")
                .font(.headline)
                .foregroundStyle(.secondary)

            Button {
                Task {
                    try await downloader.download()
                    await MainActor.run { onDownloadComplete() }
                }
            } label: {
                Label("Resume", systemImage: "play.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var completedSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Download complete")
                .font(.headline)

            Text("Installed version \(String(ModelDownloader.currentModel.commitHash.prefix(7)))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            onDownloadComplete()
        }
    }

    private func failedSection(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)

            Text("Download failed")
                .font(.headline)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                Task {
                    try await downloader.download()
                    await MainActor.run { onDownloadComplete() }
                }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#if DEBUG
#Preview {
    ModelDownloadView(downloader: ModelDownloader()) { }
}
#endif
