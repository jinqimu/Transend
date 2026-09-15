import Foundation
import Combine

/// llama.cpp 引擎更新检查与安装。
///
/// - 检查：只跟踪**正式版**（GitHub `releases/latest`，永不返回 pre-release/draft，
///   即 v 开头的稳定版）。当前正式版 release 本身不带二进制资产，只有
///   `nightly-tag.txt` 记录其快照构建（如 v0.3.0 → b10621），下载用快照标签。
/// - 安装：下载官方 macOS arm64 tarball（ghfast.top 镜像兜底）→ 解压 → 校验二进制
///   版本与 tag 一致 → 原子替换用户数据目录中的引擎（不修改 App 包内文件，
///   对 /Applications 下只读安装也安全）→ 若引擎原本在运行则自动重启。
@MainActor
final class EngineUpdater: ObservableObject {

    // MARK: - 状态

    enum CheckState: Equatable {
        case idle
        case checking
        case upToDate(current: String)
        case updateAvailable(current: String, latest: String)
        case failed(String)
    }

    enum Phase: Equatable {
        case idle
        case downloading(received: Int64, total: Int64)
        case extracting
        case installing
    }

    @Published private(set) var checkState: CheckState = .idle
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?

    private var latestTag: String?    // 下载用标签（快照构建，如 "b10621"）
    private var latestLabel: String? // 显示用正式版标签（如 "v0.3.0"）
    private var latestSize: Int64 = 0
    private var downloadProc: Process?
    private var downloadTimer: Timer?

    private static let lastCheckKey = "engineUpdateLastCheck"
    private static let autoCheckInterval: TimeInterval = 12 * 3600

    // MARK: - 对外状态

    var hasUpdate: Bool {
        if case .updateAvailable = checkState { return true }
        return false
    }

    var isDownloading: Bool {
        if case .downloading = phase { return true }
        return false
    }

    var downloadProgress: Double {
        guard case .downloading(let r, let t) = phase, t > 0 else { return 0 }
        return min(1, Double(r) / Double(t))
    }

    /// 当前生效引擎版本（与 AppPaths.engineResolution 解析规则一致）。
    /// 优先读引擎同目录 version.txt（安装/打包时写入），缺失时现场解析 `--version`。
    var currentVersion: String? {
        let res = AppPaths.engineResolution()
        if let v = AppPaths.engineVersion(at: res.url.deletingLastPathComponent()) { return v }
        return Self.readVersion(binary: res.url)
    }

    /// 设置面板显示的版本与来源，如 "b10472（内置）" / "b10752（已安装）"。
    var currentVersionDisplay: String {
        let res = AppPaths.engineResolution()
        let v = currentVersion ?? "未知"
        switch res.source {
        case .user: return "\(v)（已安装）"
        case .bundled: return "\(v)（内置）"
        case .homebrew: return "\(v)（Homebrew）"
        case .environment: return "\(v)（自定义路径）"
        }
    }

    var latestDisplay: String { latestLabel ?? latestTag ?? "未知" }

    // MARK: - 检查更新

    /// 启动时自动检查（12 小时内不重复，避免每次启动都请求 GitHub；手动检查不受限）。
    func autoCheck() {
        // HYMT2_UPDATE_ENGINE=1 为开发调试钩子：跳过 12h 节流，发现新版自动安装
        let force = ProcessInfo.processInfo.environment["HYMT2_UPDATE_ENGINE"] == "1"
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        if !force, Date().timeIntervalSince1970 - last < Self.autoCheckInterval { return }
        checkForUpdates()
    }

    func checkForUpdates() {
        guard !isBusy else { return }
        checkState = .checking
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            let latest = await self.fetchLatestStable()
            guard !Task.isCancelled else { return }
            guard let latest else {
                self.checkState = .failed("无法连接 GitHub，请检查网络后重试")
                return
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            self.latestTag = latest.tag
            self.latestLabel = latest.label
            let cur = self.currentVersion
            let curBuild = Self.build(of: cur ?? "") ?? -1
            let latestBuild = Self.build(of: latest.tag) ?? -1
            if latestBuild > curBuild {
                self.checkState = .updateAvailable(current: cur ?? "未知", latest: latest.label)
            } else {
                self.checkState = .upToDate(current: cur ?? "未知")
            }
            // 开发调试：HYMT2_UPDATE_ENGINE=1 启动时发现有新版自动安装（端到端验证用）
            if ProcessInfo.processInfo.environment["HYMT2_UPDATE_ENGINE"] == "1",
               case .updateAvailable = self.checkState {
                self.installUpdate()
            }
        }
    }

    // MARK: - 安装更新

    func installUpdate() {
        guard !isBusy, case .updateAvailable = checkState,
              let tag = latestTag else { return }
        isBusy = true
        errorMessage = nil
        let work = AppPaths.supportDir.appendingPathComponent("engine-update", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let tarball = work.appendingPathComponent("llama-\(tag)-bin-macos-arm64.tar.gz")
        download(tag: tag, to: tarball)
    }

    func cancelInstall() {
        downloadTimer?.invalidate()
        downloadTimer = nil
        downloadProc?.terminate()
        downloadProc = nil
        isBusy = false
        phase = .idle
        errorMessage = "已取消下载"
    }

    /// 清理上次可能残留的更新工作目录（启动时调用一次）。
    func cleanupStaleFiles() {
        try? FileManager.default.removeItem(
            at: AppPaths.supportDir.appendingPathComponent("engine-update", isDirectory: true))
    }

    // MARK: - 远程信息

    /// 最新**正式版** release 的可安装信息（b\* 为滚动 pre-release，一律不采用）：
    /// - 正式版 release 自带 arm64 二进制资产（`llama-<tag>-bin-macos-arm64.tar.gz`）时直接用；
    /// - 目前官方正式版（如 v0.3.0）release 只附 `nightly-tag.txt` 快照标签（如 b10621），
    ///   快照标签对应真实可下载的二进制资产。
    /// - Returns: (tag: 下载资产用标签, label: 展示用正式版标签)
    private func fetchLatestStable() async -> (tag: String, label: String)? {
        let api = URL(string: "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest")!
        guard let data = await get(url: api),
              let rel = try? JSONDecoder().decode(ReleaseBrief.self, from: data) else { return nil }
        // 防御：GitHub latest 语义已保证正式版，仍显式排除 pre-release/draft
        guard !rel.isPrerelease, !rel.isDraft else { return nil }

        if rel.assets.contains(where: { $0.name == "llama-\(rel.tagName)-bin-macos-arm64.tar.gz" }) {
            latestSize = rel.assets.first { $0.name == "llama-\(rel.tagName)-bin-macos-arm64.tar.gz" }?.size ?? 0
            return (rel.tagName, rel.tagName)
        }
        if let snap = await fetchNightlyTag(of: rel.tagName) {
            latestSize = 0
            return (snap, rel.tagName)
        }
        return nil
    }

    /// 读正式版 release 的 `nightly-tag.txt` 快照标签（GitHub 直连 + ghfast 镜像兜底）。
    private func fetchNightlyTag(of releaseTag: String) async -> String? {
        let urls = [
            "https://ghfast.top/https://github.com/ggml-org/llama.cpp/releases/download/\(releaseTag)/nightly-tag.txt",
            "https://github.com/ggml-org/llama.cpp/releases/download/\(releaseTag)/nightly-tag.txt",
        ].compactMap(URL.init(string:))
        for url in urls {
            if let s = await getString(url: url) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        return nil
    }

    private func get(url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Transend/1.0 (engine updater)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200 ? data : nil
        } catch { return nil }
    }

    private func getString(url: URL) async -> String? {
        guard let data = await get(url: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 下载

    private func download(tag: String, to dest: URL) {
        phase = .downloading(received: fileSize(of: dest), total: latestSize)
        let mirrors = [
            "https://ghfast.top/https://github.com/ggml-org/llama.cpp/releases/download/\(tag)/llama-\(tag)-bin-macos-arm64.tar.gz",
            "https://github.com/ggml-org/llama.cpp/releases/download/\(tag)/llama-\(tag)-bin-macos-arm64.tar.gz",
        ].compactMap(URL.init(string:))
        attemptDownload(urls: mirrors, dest: dest)
    }

    private func attemptDownload(urls: [URL], dest: URL) {
        guard isBusy, let url = urls.first else {
            if urls.isEmpty { failInstall("下载失败，请检查网络后重试") }
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = [
            "-L", "--fail", "--retry", "3", "--retry-all-errors",
            "--connect-timeout", "20", "--max-time", "180", // 防连接停滞导致无限挂起
            "-C", "-", // 断点续传
            "-o", dest.path,
            url.absoluteString,
        ]
        // 进度由文件大小轮询呈现，静默 curl 自身输出（避免污染宿主进程 stdout）
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] p in
            Task { @MainActor in
                guard let self, self.downloadProc === p else { return }
                self.downloadProc = nil
                let size = self.fileSize(of: dest)
                if p.terminationStatus == 0, size > 0,
                   (self.latestSize <= 0 || size == self.latestSize) {
                    self.extract(tag: self.latestTag ?? "", tarball: dest)
                } else {
                    self.attemptDownload(urls: Array(urls.dropFirst()), dest: dest)
                }
            }
        }
        downloadProc = p
        try? p.run()

        downloadTimer?.invalidate()
        downloadTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isDownloading else { return }
                self.phase = .downloading(received: self.fileSize(of: dest), total: self.latestSize)
            }
        }
    }

    // MARK: - 解压与替换

    private func extract(tag: String, tarball: URL) {
        phase = .extracting
        let work = tarball.deletingLastPathComponent()
        let unpack = work.appendingPathComponent("unpack", isDirectory: true)
        try? FileManager.default.removeItem(at: unpack)
        try? FileManager.default.createDirectory(at: unpack, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-xzf", tarball.path, "-C", unpack.path]
        p.terminationHandler = { [weak self] p in
            Task { @MainActor in
                guard let self, self.isBusy else { return }
                if p.terminationStatus == 0 {
                    self.installUnpacked(tag: tag, unpack: unpack, work: work)
                } else {
                    self.failInstall("解压失败")
                }
            }
        }
        try? p.run()
    }

    /// 校验并原子替换用户引擎目录；失败自动回滚到旧引擎。
    private func installUnpacked(tag: String, unpack: URL, work: URL) {
        phase = .installing
        let src = unpack.appendingPathComponent("llama-\(tag)", isDirectory: true)
        let binary = src.appendingPathComponent("llama-server")
        guard FileManager.default.fileExists(atPath: binary.path),
              let ver = Self.readVersion(binary: binary),
              Self.build(of: ver) == Self.build(of: tag) else {
            failInstall("引擎二进制校验失败（版本与官方 release 不符）")
            return
        }

        let wasRunning = AppState.shared.engine.isRunning
        if wasRunning {
            AppState.shared.engine.stop()
            // 等旧引擎完全退出并释放端口，避免替换文件被占用 / 重启时 bind 冲突
            waitForPortFree(timeout: 10)
        }

        let dest = AppPaths.userEngineDir
        let bak = AppPaths.supportDir.appendingPathComponent("engine.bak", isDirectory: true)
        try? FileManager.default.removeItem(at: bak)
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.moveItem(at: dest, to: bak)
        }
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            let items = try FileManager.default.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)
            for item in items {
                try FileManager.default.moveItem(at: item, to: dest.appendingPathComponent(item.lastPathComponent))
            }
        } catch {
            // 回滚
            try? FileManager.default.removeItem(at: dest)
            if FileManager.default.fileExists(atPath: bak.path) {
                try? FileManager.default.moveItem(at: bak, to: dest)
            }
            failInstall("安装失败：\(error.localizedDescription)")
            return
        }
        // version.txt 写入：正式版标签 + 快照构建，如 "v0.3.0 (b10621)"；无标签时仅构建号
        let versionStamp = latestLabel.flatMap { Self.build(of: tag) != nil ? "\($0) (\(tag))" : nil }
            ?? tag
        try? versionStamp.write(to: dest.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
        signEngine(at: dest) // 尽力重签（失败不阻塞：子进程由本 App 启动，无 Gatekeeper 校验）

        try? FileManager.default.removeItem(at: work)
        try? FileManager.default.removeItem(at: bak)

        latestTag = tag
        checkState = .upToDate(current: versionStamp)
        phase = .idle
        isBusy = false
        errorMessage = nil
        if wasRunning {
            // 重启前再等端口释放（signEngine/清理期间的时序保险），避免 bind 失败触发崩溃重启循环
            waitForPortFree(timeout: 10)
            AppState.shared.engine.start(profile: AppState.shared.selectedProfile)
        }
    }

    /// 同步等待端口 18632 无监听者（更新替换/重启前的时序保险；更新路径不多见，短暂阻塞可接受）。
    private func waitForPortFree(timeout: Double) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !Self.portInUse() { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private static func portInUse() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:18632", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        return !out.isEmpty
    }

    /// 尽力重签引擎目录（失败不阻塞：子进程由本 App 启动，无 Gatekeeper 校验）。
    /// codesign 不支持直接签裸目录（会报 "bundle format unrecognized"），
    /// 改为对目录下每个文件逐个签名，并静默其输出。
    private func signEngine(at dir: URL) {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for item in items {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            p.arguments = ["--force", "-s", "-", item.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
    }

    private func failInstall(_ msg: String) {
        downloadTimer?.invalidate()
        downloadTimer = nil
        downloadProc = nil
        phase = .idle
        isBusy = false
        errorMessage = msg
    }

    // MARK: - 工具

    private func fileSize(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// 运行 `llama-server --version` 解析构建号，返回 "b10472" 形式；失败返回 nil。
    nonisolated static func readVersion(binary: URL) -> String? {
        let p = Process()
        p.executableURL = binary
        p.arguments = ["--version"]
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        let text = (String(data: data, encoding: .utf8) ?? "")
            + (String(data: errData, encoding: .utf8) ?? "")
        let pattern = #"build\s+(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(m.range(at: 1), in: text) else { return nil }
        return "b\(text[range])"
    }

    /// 从版本串提取构建号，兼容多种格式：
    /// "b10752" / "v0.3.0 (b10621)"（正式版+快照）/ 裸数字 "10621"；无法提取返回 nil。
    nonisolated static func build(of tag: String) -> Int? {
        let s = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = Int(s), n >= 0 { return n }
        let pattern = #"b(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let range = Range(m.range(at: 1), in: s),
              let n = Int(s[range]) else { return nil }
        return n >= 0 ? n : nil
    }
}

// MARK: - GitHub API 解码

private struct ReleaseBrief: Decodable {
    let tagName: String
    let isPrerelease: Bool
    let isDraft: Bool
    let assets: [AssetBrief]
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case isPrerelease = "prerelease"
        case isDraft = "draft"
        case assets
    }
}

private struct AssetBrief: Decodable {
    let name: String
    let size: Int64
}