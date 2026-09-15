import Foundation
import Combine
import AppKit

/// 应用自身（Transend.app）的更新检查与安装。
///
/// - 检查：读 GitHub `releases/latest`（正式版，排除 pre-release/draft），
///   与 `CFBundleShortVersionString` 做语义化版本比较；12 小时内不重复自动检查。
/// - 安装分两种来源，均使用同一个 Release 产物，保证版本一致：
///   - **Homebrew 安装**（检测 `Caskroom/transend`）：不自行替换 App 包，
///     引导执行 `brew upgrade --cask transend`（可复制命令 / 在终端运行）。
///   - **普通安装**（dmg 拖拽 / zip 解压）：下载 Release 的 zip → 解压 →
///     由辅助脚本在 App 退出后原子替换当前 App 包并重启。
@MainActor
final class AppUpdater: ObservableObject {

    // MARK: - 常量

    /// 主仓库（用于查询 Release 与拼接下载地址）。
    static let repo = "jinqimu/Transend"
    static let caskName = "transend"
    let brewUpgradeCommand = "brew update && brew upgrade --cask transend"

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

    private var zipURL: URL?
    private var latestVersion: String?
    private var latestSize: Int64 = 0
    private var downloadProc: Process?
    private var downloadTimer: Timer?

    private static let lastCheckKey = "appUpdateLastCheck"
    private static let autoCheckInterval: TimeInterval = 12 * 3600

    // MARK: - 对外状态

    /// 当前 App 版本（Info.plist CFBundleShortVersionString）。
    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    /// 设置面板显示的当前版本与来源。
    var currentVersionDisplay: String {
        isBrewInstall ? "\(currentVersion)（Homebrew）" : currentVersion
    }

    /// 是否由 Homebrew 安装（Caskroom 中存在本 cask）。
    var isBrewInstall: Bool {
        let prefixes = ["/opt/homebrew", "/usr/local"]
        return prefixes.contains {
            FileManager.default.fileExists(atPath: "\($0)/Caskroom/\(Self.caskName)")
        }
    }

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

    var latestDisplay: String { latestVersion ?? "未知" }

    // MARK: - 检查更新

    /// 启动时自动检查（12 小时内不重复；手动检查不受限）。
    func autoCheck() {
        // HYMT2_UPDATE_APP=1 为开发调试钩子：跳过节流，发现新版自动安装
        let force = ProcessInfo.processInfo.environment["HYMT2_UPDATE_APP"] == "1"
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
            let result = await self.fetchLatest()
            guard !Task.isCancelled else { return }
            switch result {
            case .failure(let msg):
                self.checkState = .failed(msg)
            case .success(let release):
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
                let cur = self.currentVersion
                self.latestVersion = release.version
                self.zipURL = release.zipURL
                self.latestSize = release.zipSize
                if Self.isNewer(release.version, than: cur) {
                    self.checkState = .updateAvailable(current: cur, latest: release.version)
                } else {
                    self.checkState = .upToDate(current: cur)
                }
                // 开发调试：HYMT2_UPDATE_APP=1 发现有新版自动安装（端到端验证用）
                if ProcessInfo.processInfo.environment["HYMT2_UPDATE_APP"] == "1",
                   case .updateAvailable = self.checkState {
                    self.installUpdate()
                }
            }
        }
    }

    // MARK: - 安装更新

    func installUpdate() {
        guard !isBusy, case .updateAvailable = checkState, let version = latestVersion else { return }
        // Homebrew 安装：交由 brew 管理，不自行替换 App 包
        if isBrewInstall {
            runBrewUpgrade()
            return
        }
        guard let zipURL else {
            errorMessage = "未找到可下载的更新包（Release 缺少 zip 资产）"
            return
        }
        isBusy = true
        errorMessage = nil
        let work = AppPaths.supportDir.appendingPathComponent("app-update", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("Transend-\(version).zip")
        download(url: zipURL, to: zip)
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
            at: AppPaths.supportDir.appendingPathComponent("app-update", isDirectory: true))
    }

    /// 复制 Homebrew 升级命令到剪贴板。
    func copyBrewCommand() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(brewUpgradeCommand, forType: .string)
    }

    /// 在终端中执行 Homebrew 升级（brew 会替换 /Applications 下的 App）。
    func runBrewUpgrade() {
        let escaped = brewUpgradeCommand.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        do {
            try p.run()
        } catch {
            errorMessage = "无法打开终端：\(error.localizedDescription)"
        }
    }

    // MARK: - 远程信息

    private struct ReleaseInfo {
        let version: String
        let zipURL: URL?
        let zipSize: Int64
    }

    private enum FetchResult {
        case success(ReleaseInfo)
        case failure(String)
    }

    private func fetchLatest() async -> FetchResult {
        let api = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
        var req = URLRequest(url: api)
        req.timeoutInterval = 15
        req.setValue("Transend/1.0 (app updater)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { // 尚无任何 Release：视为已是最新
                return .success(ReleaseInfo(version: currentVersion, zipURL: nil, zipSize: 0))
            }
            guard code == 200, let rel = try? JSONDecoder().decode(ReleaseBrief.self, from: data) else {
                return .failure("无法连接 GitHub，请检查网络后重试")
            }
            guard !rel.isPrerelease, !rel.isDraft else {
                return .success(ReleaseInfo(version: currentVersion, zipURL: nil, zipSize: 0))
            }
            let version = rel.tagName.hasPrefix("v") ? String(rel.tagName.dropFirst()) : rel.tagName
            let asset = rel.assets.first { $0.name == "Transend-\(version).zip" }
            return .success(ReleaseInfo(
                version: version,
                zipURL: asset.flatMap { URL(string: $0.browserDownloadURL) },
                zipSize: asset?.size ?? 0))
        } catch {
            return .failure("无法连接 GitHub，请检查网络后重试")
        }
    }

    // MARK: - 下载

    private func download(url: URL, to dest: URL) {
        phase = .downloading(received: fileSize(of: dest), total: latestSize)
        attemptDownload(url: url, dest: dest)
    }

    private func attemptDownload(url: URL, dest: URL) {
        guard isBusy else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = [
            "-L", "--fail", "--retry", "3", "--retry-all-errors",
            "--connect-timeout", "20", "--max-time", "180",
            "-C", "-",
            "-o", dest.path,
            url.absoluteString,
        ]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] p in
            guard let self else { return }
            Task { @MainActor in
                guard self.downloadProc === p else { return }
                self.downloadProc = nil
                let size = self.fileSize(of: dest)
                if p.terminationStatus == 0, size > 0,
                   (self.latestSize <= 0 || size == self.latestSize) {
                    self.extract(zip: dest)
                } else {
                    self.failInstall("下载更新失败，请检查网络后重试")
                }
            }
        }
        downloadProc = p
        try? p.run()

        downloadTimer?.invalidate()
        downloadTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.isDownloading else { return }
                self.phase = .downloading(received: self.fileSize(of: dest), total: self.latestSize)
            }
        }
    }

    // MARK: - 解压与替换

    private func extract(zip: URL) {
        downloadTimer?.invalidate()
        downloadTimer = nil
        phase = .extracting
        let work = zip.deletingLastPathComponent()
        let unpack = work.appendingPathComponent("unpack", isDirectory: true)
        try? FileManager.default.removeItem(at: unpack)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, unpack.path]
        p.terminationHandler = { [weak self] p in
            guard let self else { return }
            Task { @MainActor in
                guard self.isBusy else { return }
                if p.terminationStatus == 0 {
                    let newApp = unpack.appendingPathComponent("Transend.app", isDirectory: true)
                    if FileManager.default.fileExists(atPath: newApp.path) {
                        self.installReplacingCurrentApp(newApp: newApp, work: work)
                    } else {
                        self.failInstall("更新包结构异常（未找到 Transend.app）")
                    }
                } else {
                    self.failInstall("解压更新包失败")
                }
            }
        }
        try? p.run()
    }

    /// 用辅助脚本在当前 App 退出后替换 App 包并重启（不修改用户数据目录）。
    private func installReplacingCurrentApp(newApp: URL, work: URL) {
        phase = .installing
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()

        // 可写性预检：/Applications 无权限时明确报错（如仅管理员可写）
        let probe = parent.appendingPathComponent(".transend-write-test-\(UUID().uuidString)")
        do {
            try Data().write(to: probe)
            try FileManager.default.removeItem(at: probe)
        } catch {
            failInstall("无写入权限（\(parent.path)），请手动下载新版替换")
            return
        }

        let script = work.appendingPathComponent("install.sh")
        let body = """
        #!/bin/sh
        # 由 Transend 自更新器生成：等待旧进程退出 → 原子替换 App 包 → 重启。
        pid="$1"; newapp="$2"; target="$3"
        i=0
        while kill -0 "$pid" 2>/dev/null; do
            sleep 0.3
            i=$((i+1))
            [ "$i" -gt 100 ] && break
        done
        sleep 0.5
        backup="${target}.old.$$"
        if ! mv "$target" "$backup" 2>/dev/null; then
            exit 1
        fi
        if ditto "$newapp" "$target"; then
            rm -rf "$backup"
            xattr -dr com.apple.quarantine "$target" 2>/dev/null
            open "$target"
        else
            rm -rf "$target"
            mv "$backup" "$target"
            open "$target"
        fi
        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            failInstall("准备更新脚本失败：\(error.localizedDescription)")
            return
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c",
            "nohup /bin/sh '\(script.path)' \(pid) '\(newApp.path)' '\(target.path)' >/dev/null 2>&1 &"]
        do {
            try p.run()
        } catch {
            failInstall("启动更新脚本失败：\(error.localizedDescription)")
            return
        }
        // 退出当前实例，交给脚本完成替换与重启
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
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

    /// 语义化版本比较：latest 是否比 current 新（忽略前导 v；缺失段按 0 处理）。
    nonisolated static func isNewer(_ latest: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            return trimmed.split(separator: ".").map {
                Int($0.prefix(while: { $0.isNumber })) ?? 0
            }
        }
        let l = parts(latest), c = parts(current)
        for i in 0..<max(l.count, c.count) {
            let a = i < l.count ? l[i] : 0
            let b = i < c.count ? c[i] : 0
            if a != b { return a > b }
        }
        return false
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
    let browserDownloadURL: String
    enum CodingKeys: String, CodingKey {
        case name
        case size
        case browserDownloadURL = "browser_download_url"
    }
}
