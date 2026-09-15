import Foundation

enum AppPaths {
    /// 旧版（HyMT2）数据目录迁移到新目录，避免模型重新下载。
    static func migrateIfNeeded() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let old = base.appendingPathComponent("HyMT2", isDirectory: true)
        let new = base.appendingPathComponent("Transend", isDirectory: true)
        if FileManager.default.fileExists(atPath: old.path),
           !FileManager.default.fileExists(atPath: new.path) {
            try? FileManager.default.moveItem(at: old, to: new)
        }
    }

    /// ~/Library/Application Support/Transend
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Transend", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 模型目录（HYMT2_MODELS_DIR 环境变量可覆盖，便于开发测试）
    static var modelsDir: URL {
        if let env = ProcessInfo.processInfo.environment["HYMT2_MODELS_DIR"], !env.isEmpty {
            try? FileManager.default.createDirectory(at: URL(fileURLWithPath: env), withIntermediateDirectories: true)
            return URL(fileURLWithPath: env)
        }
        let dir = supportDir.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func modelURL(for profile: ModelProfile) -> URL {
        modelsDir.appendingPathComponent(profile.fileName)
    }

    static var engineLogURL: URL {
        supportDir.appendingPathComponent("engine.log")
    }

    /// 引擎 PID 文件（用于清理上次异常退出残留的孤儿进程）
    static var enginePIDURL: URL {
        supportDir.appendingPathComponent("engine.pid")
    }

    // MARK: - 引擎（内置 / 用户更新安装）

    /// 用户安装的引擎目录：引擎更新安装到这里，不修改 App 包内文件
    /// （/Applications 下只读、签名保护均不受影响）。
    static var userEngineDir: URL {
        let dir = supportDir.appendingPathComponent("engine", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// App 内置引擎目录（存在时才返回）。
    static var bundledEngineDir: URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let dir = res.appendingPathComponent("engine", isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    /// 读引擎目录的版本标记（llama-server 同目录下 version.txt，如 "b10472"；
    /// 打包脚本与引擎更新器都会写入）。
    static func engineVersion(at dir: URL) -> String? {
        let url = dir.appendingPathComponent("version.txt")
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    /// 引擎二进制来源。
    enum EngineSource {
        case user      // 用户数据目录（更新安装）
        case bundled   // App 内置
        case homebrew  // /opt/homebrew/bin
        case environment // LLAMA_SERVER_PATH（开发调试）
    }

    /// 引擎二进制解析：环境变量（开发调试）→ 用户/内置引擎（构建号高者生效，
    /// 同级优先用户已安装）→ Homebrew 兜底。
    static func engineResolution() -> (url: URL, source: EngineSource) {
        if let env = ProcessInfo.processInfo.environment["LLAMA_SERVER_PATH"], !env.isEmpty {
            return (URL(fileURLWithPath: env), .environment)
        }

        var candidates: [(url: URL, build: Int)] = []
        let userBin = userEngineDir.appendingPathComponent("llama-server")
        if FileManager.default.fileExists(atPath: userBin.path) {
            candidates.append((userBin, engineBuildNumber(at: userEngineDir)))
        }
        if let dir = bundledEngineDir {
            let bundledBin = dir.appendingPathComponent("llama-server")
            if FileManager.default.fileExists(atPath: bundledBin.path) {
                candidates.append((bundledBin, engineBuildNumber(at: dir)))
            }
        }

        // 取构建号最高者；相同构建号保留先加入的（user 优先于 bundled）
        var best = candidates.first
        for c in candidates.dropFirst() {
            if let b = best, c.build > b.build { best = c }
        }
        if let best {
            let source: EngineSource = best.url.path.hasPrefix(userEngineDir.path) ? .user : .bundled
            return (best.url, source)
        }
        return (URL(fileURLWithPath: "/opt/homebrew/bin/llama-server"), .homebrew)
    }

    /// 引擎二进制：App 内置 → LLAMA_SERVER_PATH 环境变量（开发调试）→ Homebrew。
    static var engineBinaryURL: URL {
        engineResolution().url
    }

    /// 从引擎版本串提取构建号（与 EngineUpdater.build(of:) 同规则），
    /// 兼容 "b10472" / "v0.3.0 (b10621)" / 裸数字；提取失败返回 0。
    private static func engineBuildNumber(at dir: URL) -> Int {
        guard let v = engineVersion(at: dir)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return 0 }
        if let n = Int(v), n >= 0 { return n }
        let pattern = #"b(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: v, range: NSRange(v.startIndex..., in: v)),
              let range = Range(m.range(at: 1), in: v),
              let n = Int(v[range]) else { return 0 }
        return n >= 0 ? n : 0
    }
}
