import Foundation
import os

/// Downloads `.litertlm` model files with progress tracking, pause/resume, and cancellation.
///
/// ## Usage
/// ```swift
/// let downloader = ModelDownloader()
///
/// // Download from HuggingFace
/// try await downloader.download(from: ModelDownloader.defaultModelURL)
///
/// // Track progress
/// let progress = downloader.progress  // 0.0 ... 1.0
/// let status = downloader.status      // .downloading, .paused, etc.
///
/// // Use with LiteRTLMEngine
/// let engine = LiteRTLMEngine(modelPath: downloader.modelPath)
/// ```
@Observable
final class ModelDownloader: NSObject, @unchecked Sendable {

    // MARK: - Types

    enum DownloadStatus: Sendable, Equatable {
        case notStarted
        case downloading(progress: Double)
        case paused(progress: Double)
        case completed
        case failed(String)
    }

    enum DownloadError: LocalizedError {
        case invalidHTTPResponse(Int)
        case fileOperationFailed(String)
        case alreadyDownloading

        var errorDescription: String? {
            switch self {
            case .invalidHTTPResponse(let code): "Server returned HTTP \(code)"
            case .fileOperationFailed(let reason): reason
            case .alreadyDownloading: "A download is already in progress"
            }
        }
    }

    struct ModelManifest: Codable, Equatable, Sendable {
        let name: String
        let modelID: String
        let filename: String
        let commitHash: String
        let previousCommitHashes: [String]
        let sizeInBytes: Int64
        let updateInfo: String

        var downloadURL: URL {
            URL(
                string: "https://huggingface.co/\(modelID)/resolve/\(commitHash)/\(filename)?download=true"
            )!
        }
    }

    struct InstalledModelMetadata: Codable, Equatable, Sendable {
        let name: String
        let modelID: String
        let filename: String
        let commitHash: String
        let installedAt: Date
        let sizeInBytes: Int64
    }

    enum ModelUpdateState: Equatable {
        case missing
        case current
        case updateAvailable(installedVersion: String?)

        var isUpdateAvailable: Bool {
            if case .updateAvailable = self { return true }
            return false
        }
    }

    // MARK: - Properties

    var status: DownloadStatus = .notStarted
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0

    /// Progress from 0.0 to 1.0.
    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(Double(downloadedBytes) / Double(totalBytes), 1.0)
    }

    /// Whether the model file exists on disk.
    var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelPath.path)
    }

    /// Current model manifest. Mirrors Google AI Edge Gallery's Gemma 4 E2B update line.
    static let currentModel = ModelManifest(
        name: "Gemma 4 E2B",
        modelID: "litert-community/gemma-4-E2B-it-litert-lm",
        filename: "gemma-4-E2B-it.litertlm",
        commitHash: "3f25054",
        previousCommitHashes: [
            "6e5c4f1e395deb959c494953478fa5cec4b8008f",
            "7fa1d78473894f7e736a21d920c3aa80f950c0db"
        ],
        sizeInBytes: 2_588_147_712,
        updateInfo: "A newer Gemma 4 E2B model is available. Update to refresh the local on-device model."
    )

    /// Default HuggingFace URL for Gemma 4 E2B LiteRT-LM model.
    static let defaultModelURL = currentModel.downloadURL

    /// Default model filename.
    static let defaultModelFilename = currentModel.filename

    /// Stable identifier iOS uses to continue and relaunch the background download session.
    static let backgroundSessionIdentifier = "com.guardai.ios.model-download"

    /// Directory where models are stored.
    let modelsDirectory: URL

    /// Full path to the model file.
    var modelPath: URL {
        modelsDirectory.appendingPathComponent(Self.defaultModelFilename)
    }

    private var _session: URLSession?
    private var session: URLSession {
        if let s = _session { return s }
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 24 * 60 * 60
        config.httpMaximumConnectionsPerHost = 2
        let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        _session = s
        return s
    }

    private var activeTask: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<Void, any Error>?
    private let lock = NSLock()
    private var pendingManifest: ModelManifest?

    // Resume support
    private var resumeData: Data?
    private var isPausing = false
    private var resumeOffset: Int64 = 0
    private var knownTotal: Int64 = 0

    private static let log = Logger(subsystem: "LiteRTLMSwift", category: "Downloader")

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Init

    /// Create a downloader.
    /// - Parameter modelsDirectory: Where to store downloaded models.
    ///   Defaults to `~/Library/Application Support/LiteRTLM/Models/`.
    init(modelsDirectory: URL? = nil) {
        self.modelsDirectory = modelsDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiteRTLM/Models", isDirectory: true)
        super.init()

        if isDownloaded {
            status = .completed
            totalBytes = installedMetadata?.sizeInBytes ?? Self.currentModel.sizeInBytes
        } else if loadResumeData() != nil {
            let meta = loadResumeMetadata()
            status = .paused(progress: meta?.progress ?? 0)
            if let meta {
                downloadedBytes = meta.downloadedBytes
                totalBytes = meta.totalBytes
            }
        }

        restoreActiveBackgroundTask()
    }

    // MARK: - Download

    /// Download the model file.
    /// - Parameter url: URL to download from. Defaults to `defaultModelURL`.
    func download(from url: URL = defaultModelURL) async throws {
        try await download(from: url, manifest: Self.currentModel, replacingExisting: false)
    }

    /// Download and install the app's required target model, replacing an older local file.
    func updateToLatestModel() async throws {
        let manifest = ModelManifest(
            name: Self.currentModel.name,
            modelID: Self.currentModel.modelID,
            filename: Self.currentModel.filename,
            commitHash: Self.currentModel.commitHash,
            previousCommitHashes: Self.currentModel.previousCommitHashes,
            sizeInBytes: Self.currentModel.sizeInBytes,
            updateInfo: Self.currentModel.updateInfo
        )
        try await download(
            from: manifest.downloadURL,
            manifest: manifest,
            replacingExisting: true
        )
    }

    private func download(
        from url: URL,
        manifest: ModelManifest,
        replacingExisting: Bool
    ) async throws {
        guard replacingExisting || !isDownloaded else {
            Self.log.info("Model already on disk, skipping download")
            status = .completed
            return
        }

        let isActive = withLock { continuation != nil }
        guard !isActive else {
            throw DownloadError.alreadyDownloading
        }

        if let existingTask = withLock({ activeTask }) {
            status = .downloading(progress: progress)
            return try await withCheckedThrowingContinuation { cont in
                withLock { continuation = cont }
                existingTask.resume()
            }
        }

        await awaitExistingBackgroundTaskIfNeeded()
        guard replacingExisting || !isDownloaded else {
            status = .completed
            return
        }

        let taskRestored = withLock { activeTask != nil }
        if taskRestored {
            status = .downloading(progress: progress)
            return try await withCheckedThrowingContinuation { cont in
                withLock { continuation = cont }
            }
        }

        status = .downloading(progress: progress)
        withLock {
            pendingManifest = manifest
        }
        if replacingExisting {
            clearResumeData()
            downloadedBytes = 0
            totalBytes = manifest.sizeInBytes
        }

        try FileManager.default.createDirectory(
            at: modelsDirectory, withIntermediateDirectories: true
        )

        let task: URLSessionDownloadTask
        if let data = loadResumeData() {
            task = session.downloadTask(withResumeData: data)
            Self.log.info("Resuming download")
        } else {
            task = session.downloadTask(with: url)
            Self.log.info("Starting download from \(url.absoluteString)")
        }

        withLock {
            activeTask = task
            resumeOffset = 0
            knownTotal = 0
        }

        return try await withCheckedThrowingContinuation { cont in
            withLock { continuation = cont }
            task.resume()
        }
    }

    // MARK: - Pause / Resume / Cancel

    /// Pause the active download, saving resume data for later continuation.
    func pause() {
        withLock { isPausing = true }
        activeTask?.cancel(byProducingResumeData: { _ in })
    }

    /// Cancel the download and discard resume data.
    func cancel() {
        activeTask?.cancel()
        clearResumeData()
        status = .notStarted
        downloadedBytes = 0
        totalBytes = 0
    }

    /// Delete the downloaded model file.
    func deleteModel() {
        try? FileManager.default.removeItem(at: modelPath)
        try? FileManager.default.removeItem(at: metadataPath)
        clearResumeData()
        status = .notStarted
        downloadedBytes = 0
        totalBytes = 0
        Self.log.info("Model deleted")
    }

    // MARK: - Display Helpers

    var downloadedBytesDisplay: String {
        ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
    }

    var totalBytesDisplay: String {
        guard totalBytes > 0 else {
            return ByteCountFormatter.string(fromByteCount: Self.currentModel.sizeInBytes, countStyle: .file)
        }
        return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    var installedMetadata: InstalledModelMetadata? {
        guard let data = try? Data(contentsOf: metadataPath),
              let metadata = try? JSONDecoder().decode(InstalledModelMetadata.self, from: data) else {
            return nil
        }
        return metadata
    }

    var modelUpdateState: ModelUpdateState {
        guard isDownloaded else { return .missing }
        guard let metadata = installedMetadata else {
            return .updateAvailable(installedVersion: nil)
        }
        if Self.matchesCurrentModelCommit(metadata.commitHash) {
            return .current
        }
        return .updateAvailable(installedVersion: metadata.commitHash)
    }

    /// The latest commit hash from the Hugging Face API. Nil until checked.
    private(set) var latestRemoteCommitHash: String?

    /// Checks the Hugging Face API for the latest commit on the model repo.
    /// This is diagnostic metadata only; the app's required model target is
    /// `currentModel.commitHash`.
    /// Updates `latestRemoteCommitHash` if successful. Safe to call on any thread.
    /// Fails silently for offline users.
    func checkForRemoteUpdate() async {
        let urlString = "https://huggingface.co/api/models/\(Self.currentModel.modelID)"
        guard let url = URL(string: urlString) else { return }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return }

            // The API returns JSON with a "sha" field containing the latest commit hash
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sha = json["sha"] as? String, !sha.isEmpty else { return }

            latestRemoteCommitHash = sha
            Self.log.info("Remote model check: latest commit \(sha.prefix(7))")
        } catch {
            // Fail silently — offline users keep the pinned hash comparison
            Self.log.info("Remote model check failed (offline?): \(error.localizedDescription)")
        }
    }

    /// The download URL for the app's required target model.
    var latestDownloadURL: URL {
        return URL(
            string: "https://huggingface.co/\(Self.currentModel.modelID)/resolve/\(Self.currentModel.commitHash)/\(Self.currentModel.filename)?download=true"
        )!
    }

    // MARK: - Resume Data Persistence

    private var resumeDataDirectory: URL {
        modelsDirectory.appendingPathComponent(".resumedata", isDirectory: true)
    }

    private var metadataPath: URL {
        modelsDirectory.appendingPathComponent("\(Self.defaultModelFilename).metadata.json")
    }

    private var resumeDataPath: URL {
        resumeDataDirectory.appendingPathComponent("model.resume")
    }

    private var resumeMetadataPath: URL {
        resumeDataDirectory.appendingPathComponent("model.meta")
    }

    private struct ResumeMetadata: Codable {
        let downloadedBytes: Int64
        let totalBytes: Int64
        let commitHash: String?
        var progress: Double {
            guard totalBytes > 0 else { return 0 }
            return Double(downloadedBytes) / Double(totalBytes)
        }
    }

    private func saveResumeData(_ data: Data) {
        withLock { resumeData = data }
        do {
            try FileManager.default.createDirectory(at: resumeDataDirectory, withIntermediateDirectories: true)
            try data.write(to: resumeDataPath)
            let manifest = withLock { pendingManifest ?? Self.currentModel }
            let meta = ResumeMetadata(
                downloadedBytes: downloadedBytes,
                totalBytes: totalBytes,
                commitHash: manifest.commitHash
            )
            if let metaData = try? JSONEncoder().encode(meta) {
                try? metaData.write(to: resumeMetadataPath)
            }
        } catch {
            Self.log.error("Failed to save resume data: \(error.localizedDescription)")
        }
    }

    private func loadResumeData() -> Data? {
        if let data = withLock({ resumeData }) { return data }
        guard let meta = loadResumeMetadata(),
              let commitHash = meta.commitHash,
              Self.matchesCurrentModelCommit(commitHash) else {
            clearResumeData()
            return nil
        }
        guard let data = try? Data(contentsOf: resumeDataPath) else { return nil }
        withLock { resumeData = data }
        return data
    }

    private func loadResumeMetadata() -> ResumeMetadata? {
        guard let data = try? Data(contentsOf: resumeMetadataPath),
              let meta = try? JSONDecoder().decode(ResumeMetadata.self, from: data) else { return nil }
        return meta
    }

    private func restoreActiveBackgroundTask() {
        session.getAllTasks { [weak self] tasks in
            guard let self,
                  let task = tasks.compactMap({ $0 as? URLSessionDownloadTask }).first else { return }

            self.withLock { self.activeTask = task }

            Task { @MainActor in
                if !self.isDownloaded {
                    self.status = .downloading(progress: self.progress)
                }
            }
        }
    }

    private func awaitExistingBackgroundTaskIfNeeded() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.getAllTasks { [weak self] tasks in
                defer { continuation.resume() }
                guard let self,
                      let task = tasks.compactMap({ $0 as? URLSessionDownloadTask }).first else { return }
                self.withLock { self.activeTask = task }
            }
        }
    }

    private func clearResumeData() {
        withLock { resumeData = nil }
        try? FileManager.default.removeItem(at: resumeDataPath)
        try? FileManager.default.removeItem(at: resumeMetadataPath)
    }

    private func saveInstalledMetadata(for manifest: ModelManifest) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: modelPath.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? manifest.sizeInBytes
        let metadata = InstalledModelMetadata(
            name: manifest.name,
            modelID: manifest.modelID,
            filename: manifest.filename,
            commitHash: manifest.commitHash,
            installedAt: Date(),
            sizeInBytes: size
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(metadata).write(to: metadataPath)
        } catch {
            Self.log.error("Failed to save model metadata: \(error.localizedDescription)")
        }
    }

    private static func matchesCurrentModelCommit(_ commitHash: String) -> Bool {
        let target = currentModel.commitHash
        return commitHash == target
            || commitHash.hasPrefix(target)
            || target.hasPrefix(commitHash)
    }

    private func finish(result: Result<Void, any Error>) {
        let cont = withLock {
            let c = continuation
            continuation = nil
            activeTask = nil
            resumeOffset = 0
            knownTotal = 0
            pendingManifest = nil
            return c
        }
        cont?.resume(with: result)
    }

    @MainActor
    private func setFailed(_ message: String) {
        status = .failed(message)
    }

    @MainActor
    private func setCompleted() {
        status = .completed
    }
}

enum BackgroundDownloadSessionEvents {
    private static let lock = NSLock()
    private static var completionHandler: (() -> Void)?

    static func setCompletionHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        completionHandler = handler
        lock.unlock()
    }

    static func finish() {
        lock.lock()
        let handler = completionHandler
        completionHandler = nil
        lock.unlock()
        handler?()
    }
}

// MARK: - URLSessionDownloadDelegate

extension ModelDownloader: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            Self.log.error("Download failed: HTTP \(http.statusCode)")
            clearResumeData()
            Task { @MainActor in
                self.downloadedBytes = 0
                self.totalBytes = 0
                self.setFailed("HTTP \(http.statusCode)")
            }
            finish(result: .failure(DownloadError.invalidHTTPResponse(http.statusCode)))
            return
        }

        do {
            let stagedModelPath = modelsDirectory.appendingPathComponent("\(Self.defaultModelFilename).installing")
            if FileManager.default.fileExists(atPath: stagedModelPath.path) {
                try FileManager.default.removeItem(at: stagedModelPath)
            }
            try FileManager.default.moveItem(at: location, to: stagedModelPath)

            if FileManager.default.fileExists(atPath: modelPath.path) {
                _ = try FileManager.default.replaceItemAt(
                    modelPath,
                    withItemAt: stagedModelPath,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try FileManager.default.moveItem(at: stagedModelPath, to: modelPath)
            }

            Self.log.info("Download completed")
            clearResumeData()
            let manifest = withLock { pendingManifest ?? Self.currentModel }
            saveInstalledMetadata(for: manifest)
            Task { @MainActor in
                self.totalBytes = manifest.sizeInBytes
                self.setCompleted()
            }
            finish(result: .success(()))
        } catch {
            Self.log.error("File move failed: \(error.localizedDescription)")
            Task { @MainActor in
                self.setFailed(error.localizedDescription)
            }
            finish(result: .failure(DownloadError.fileOperationFailed(error.localizedDescription)))
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }

        let offset = withLock { resumeOffset }
        let total = withLock { knownTotal > 0 ? knownTotal : (offset + totalBytesExpectedToWrite) }
        let downloaded = offset + totalBytesWritten
        let prog = total > 0 ? min(Double(downloaded) / Double(total), 1.0) : 0

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.status = .downloading(progress: prog)
            self.downloadedBytes = downloaded
            self.totalBytes = total
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64
    ) {
        Self.log.info("Resumed at offset \(ByteCountFormatter.string(fromByteCount: fileOffset, countStyle: .file))")
        withLock {
            resumeOffset = fileOffset
            if expectedTotalBytes > 0 { knownTotal = expectedTotalBytes }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error else { return }

        let isPause = withLock {
            let was = isPausing
            isPausing = false
            return was
        }
        let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data

        if let data { saveResumeData(data) }
        else if !isPause { clearResumeData() }

        if isPause {
            Self.log.info("Download paused at \(Int(self.progress * 100))%")
            Task { @MainActor in
                self.status = .paused(progress: self.progress)
            }
            finish(result: .failure(CancellationError()))
        } else if (error as NSError).code == NSURLErrorCancelled {
            Task { @MainActor in
                self.status = .notStarted
            }
            finish(result: .failure(CancellationError()))
        } else {
            Self.log.error("Download error: \(error.localizedDescription)")
            Task { @MainActor in
                if data != nil {
                    self.status = .paused(progress: self.progress)
                } else {
                    self.status = .failed(error.localizedDescription)
                }
            }
            finish(result: .failure(error))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            BackgroundDownloadSessionEvents.finish()
        }
    }
}
