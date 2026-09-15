import Foundation
import Combine

/// 用 curl 下载模型 GGUF：断点续传（-C -）、进度轮询、失败可重试。
@MainActor
final class Downloader: ObservableObject {

    @Published private(set) var isDownloading = false
    @Published private(set) var downloadedBytes: Int64 = 0
    @Published private(set) var error: String?

    private var proc: Process?
    private var timer: Timer?
    private var urls: [URL] = []
    private var sizeBytes: Int64 = 0
    private var dest: URL?
    private var onSuccess: (() -> Void)?

    var progress: Double {
        guard sizeBytes > 0 else { return 0 }
        return min(1, Double(downloadedBytes) / Double(sizeBytes))
    }

    // MARK: - 下载

    func start(urls: [URL], sizeBytes: Int64, dest: URL, onSuccess: (() -> Void)? = nil) {
        guard !isDownloading else { return }
        // 已有文件处理：小于预期且头部完好 → 保留，curl -C - 断点续传；
        // 大小异常（>= 预期）或头部损坏 → 删除重新下载（续传只会延续损坏）。
        let existing = fileSize(of: dest)
        if existing > 0, existing >= sizeBytes || !isValidGGUF(dest) {
            try? FileManager.default.removeItem(at: dest)
        }
        self.urls = urls
        self.sizeBytes = sizeBytes
        self.dest = dest
        self.onSuccess = onSuccess
        isDownloading = true
        downloadedBytes = fileSize(of: dest)
        error = nil
        attempt(urls: urls, dest: dest)
    }

    func retry() {
        guard let dest, !urls.isEmpty else { return }
        start(urls: urls, sizeBytes: sizeBytes, dest: dest, onSuccess: onSuccess)
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        proc?.terminate()
        proc = nil
        isDownloading = false
        urls = []
        sizeBytes = 0
        dest = nil
        onSuccess = nil
        error = "已取消下载" // 供 UI 提示；下次开始下载时自动清除
    }

    // MARK: - 实现

    private func attempt(urls: [URL], dest: URL) {
        guard isDownloading else { return }
        guard let url = urls.first else {
            finish(error: "下载失败，请检查网络后重试")
            return
        }
        try? FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = [
            "-L", "--fail", "--retry", "3", "--retry-all-errors",
            "-C", "-", // 断点续传
            "-o", dest.path,
            url.absoluteString,
        ]
        p.terminationHandler = { [weak self] p in
            Task { @MainActor in
                guard let self, self.proc === p else { return }
                self.proc = nil
                let size = self.fileSize(of: dest)
                if p.terminationStatus == 0 || size >= self.sizeBytes {
                    self.finishSuccess()
                } else {
                    self.attempt(urls: Array(urls.dropFirst()), dest: dest) // 换备用地址续传
                }
            }
        }
        proc = p
        try? p.run()

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.downloadedBytes = self?.fileSize(of: dest) ?? 0
            }
        }
    }

    private func finishSuccess() {
        timer?.invalidate()
        timer = nil
        isDownloading = false
        downloadedBytes = sizeBytes
        urls = []
        sizeBytes = 0
        dest = nil
        let cb = onSuccess
        onSuccess = nil
        cb?()
    }

    private func finish(error: String) {
        timer?.invalidate()
        timer = nil
        isDownloading = false
        self.error = error
        urls = []
        sizeBytes = 0
        dest = nil
        onSuccess = nil
    }

    private func fileSize(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// 头部 magic 是否为 "GGUF"（0x47 47 55 46），用于识别残缺文件。
    private func isValidGGUF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return handle.readData(ofLength: 4) == Data([0x47, 0x47, 0x55, 0x46])
    }
}
