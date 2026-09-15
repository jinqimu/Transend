import Foundation
import Combine

/// 管理 llama-server 子进程：启动、健康检查、崩溃自动重启（指数退避）、日志落盘。
@MainActor
final class Engine: ObservableObject {

    enum State: Equatable {
        case stopped
        case starting
        case running
        case failed(String)

        var label: String {
            switch self {
            case .stopped: return "未运行"
            case .starting: return "启动中…"
            case .running: return "运行中"
            case .failed(let msg): return "错误：\(msg)"
            }
        }
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var restartCount = 0

    let port: UInt16 = 18632
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var isRunning: Bool { state == .running }

    private var proc: Process?
    private var healthTask: Task<Void, Never>?
    private var profile: ModelProfile?
    private var stopRequested = false
    private var fastFailures = 0
    private var logHandle: FileHandle?

    // MARK: - 启停

    func start(profile: ModelProfile) {
        guard proc == nil else { return }
        guard FileManager.default.fileExists(atPath: AppPaths.modelURL(for: profile).path) else {
            state = .failed("模型未下载")
            return
        }
        let bin = AppPaths.engineBinaryURL
        guard FileManager.default.fileExists(atPath: bin.path) else {
            state = .failed("未找到 llama-server（先运行 Scripts/build-app.sh）")
            return
        }
        stopRequested = false
        fastFailures = 0
        restartCount = 0
        self.profile = profile
        cleanupPort() // 清理残留引擎（孤儿进程/端口占用），确保本次能绑定
        spawn(binary: bin, modelURL: AppPaths.modelURL(for: profile))
    }

    func stop() {
        stopRequested = true
        healthTask?.cancel()
        healthTask = nil
        proc?.terminate()
        proc = nil
        try? FileManager.default.removeItem(at: AppPaths.enginePIDURL)
        state = .stopped
        restartCount = 0
        fastFailures = 0
    }

    /// 清理占用端口的残留进程：先按 PID 文件（上次本 App 的引擎），
    /// 再 lsof 清扫端口上所有监听者兜底（覆盖 PID 文件缺失等场景）。
    private func cleanupPort() {
        let pidURL = AppPaths.enginePIDURL
        if let pidStr = try? String(contentsOf: pidURL, encoding: .utf8),
           let pid = pid_t(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 0, kill(pid, 0) == 0 {
            kill(pid, SIGTERM)
            var alive = true
            for _ in 0..<20 {
                if kill(pid, 0) != 0 { alive = false; break }
                usleep(100_000)
            }
            if alive { kill(pid, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: pidURL)

        // 兜底：清扫端口上的所有残留监听者
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        let pids = String(data: out, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
            ?? []
        if !pids.isEmpty {
            for pid in pids where pid > 0 { kill(pid, SIGTERM) }
            usleep(300_000)
        }
    }

    // MARK: - 子进程

    private func spawn(binary: URL, modelURL: URL) {
        state = .starting

        let p = Process()
        p.executableURL = binary
        p.arguments = [
            "--model", modelURL.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--ctx-size", "4096",
            "--n-gpu-layers", "99",
            "--parallel", "1",
            "--no-webui",
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        // 日志落盘（文件需先创建）
        let logURL = AppPaths.engineLogURL
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: logURL)
        try? logHandle?.truncate(atOffset: 0)
        let logHandle = logHandle
        for pipe in [outPipe, errPipe] {
            pipe.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                guard !data.isEmpty else { return }
                try? logHandle?.write(contentsOf: data)
            }
        }

        p.terminationHandler = { [weak self] p in
            Task { @MainActor in
                self?.onExit(p)
            }
        }

        do {
            try p.run()
            proc = p
            try? String(p.processIdentifier).write(to: AppPaths.enginePIDURL, atomically: true, encoding: .utf8)
        } catch {
            state = .failed("启动引擎失败：\(error.localizedDescription)")
            return
        }
        pollHealth()
    }

    /// 进程退出（正常 stop 之外均为意外退出）。
    /// - Parameter p: 退出的子进程。只处理「当前引擎进程」的退出：
    ///   被 stop/替换 后旧进程的迟到回调（模型卸载可能耗时数秒）直接忽略，
    ///   否则会误触发崩溃重启循环。
    private func onExit(_ p: Process) {
        guard proc === p else { return }
        healthTask?.cancel()
        healthTask = nil
        proc = nil
        logHandle = nil
        try? FileManager.default.removeItem(at: AppPaths.enginePIDURL)

        guard !stopRequested else {
            state = .stopped
            return
        }
        guard let profile, FileManager.default.fileExists(atPath: AppPaths.modelURL(for: profile).path) else {
            state = .failed("模型文件缺失")
            return
        }
        fastFailures += 1
        if fastFailures > 5 {
            state = .failed("引擎连续启动失败，请查看日志")
            return
        }
        restartCount += 1
        let delay = Double(min(1 << fastFailures, 30)) // 2,4,8,16,30 秒退避
        state = .starting
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            // 双保险：期间引擎已被手动启动/健康运行（state != .starting）则不再重启
            guard let self, self.proc == nil, !self.stopRequested, self.state == .starting else { return }
            self.spawn(binary: AppPaths.engineBinaryURL, modelURL: AppPaths.modelURL(for: profile))
        }
    }

    // MARK: - 健康检查

    private func pollHealth() {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(180)
            while !Task.isCancelled {
                if await self?.ping() == true {
                    self?.fastFailures = 0
                    self?.state = .running
                    return
                }
                if Date() > deadline {
                    self?.state = .failed("引擎启动超时，请查看日志")
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func ping() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        req.timeoutInterval = 3
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
