import Foundation

/// 目标语言（官方 33+ 语言，全称用于提示词）。
struct Language: Identifiable, Hashable {
    let code: String
    let english: String // 英文全称，用于英文提示词
    let chinese: String // 中文名，用于中文提示词
    var id: String { code }
}

/// 官方推荐采样参数（1.8B/7B）。
struct SamplingParams: Equatable {
    let temperature: Double
    let topP: Double
    let topK: Int
    let repetitionPenalty: Double
    let maxTokens: Int
}

/// 提示词模板。不同模型模板不同，后续换模型在此扩展。
enum PromptTemplate {
    case hyMT2

    func build(text: String, targetName: String, chinesePrompt: Bool) -> String {
        switch self {
        case .hyMT2:
            // 官方模板：https://github.com/Tencent-Hunyuan/Hy-MT2
            if chinesePrompt {
                return "将以下文本翻译为 \(targetName)，注意只需要输出翻译后的结果，不要额外解释：\n\n\(text)"
            }
            return "Translate the following text into \(targetName). Note that you should only output the translated result without any additional explanation:\n\n\(text)"
        }
    }
}

/// 请求端点。不同模型/GGUF 的 chat template 支持情况不同。
enum EngineEndpoint {
    case chatCompletions // OpenAI 兼容 /v1/chat/completions（需 GGUF 内嵌 chat template）
    case completion      // 原始 /completion（llama.cpp 官方推荐用法，无需 template）

    var path: String {
        switch self {
        case .chatCompletions: return "v1/chat/completions"
        case .completion: return "completion"
        }
    }
}

/// 模型下载源。
enum DownloadSource: String, CaseIterable, Identifiable {
    case huggingface
    case hfMirror
    case modelscope

    var id: String { rawValue }

    var label: String {
        switch self {
        case .huggingface: return "HuggingFace"
        case .hfMirror: return "HF Mirror"
        case .modelscope: return "modelscope（国内推荐）"
        }
    }

    /// 模型文件下载 URL（modelscope 用 master 分支，其余用 main）。
    func url(repoPath: String, fileName: String) -> URL {
        switch self {
        case .huggingface:
            return URL(string: "https://huggingface.co/\(repoPath)/resolve/main/\(fileName)")!
        case .hfMirror:
            return URL(string: "https://hf-mirror.com/\(repoPath)/resolve/main/\(fileName)")!
        case .modelscope:
            return URL(string: "https://modelscope.cn/models/\(repoPath)/resolve/master/\(fileName)")!
        }
    }
}

/// 模型档案：描述一个模型如何下载、加载、构造提示词、请求与解析。
/// 换模型 = 新增一个 profile 并切换，引擎/下载/UI 均不感知差异。
struct ModelProfile: Identifiable {
    let id: String
    let name: String
    let repoPath: String
    let fileName: String
    let sizeBytes: Int64
    let template: PromptTemplate
    let endpoint: EngineEndpoint
    let sampling: SamplingParams
    let languages: [Language]

    /// 文件是否完整可用：存在 + 大小与预期一致 + GGUF 头部 magic 校验。
    /// 残缺文件（下载中断/被截断）大小不符或头部损坏，会正确识别为"未下载"，
    /// 避免引擎加载残缺文件卡在启动中。
    func isDownloaded(at url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              size == sizeBytes else { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return handle.readData(ofLength: 4) == Data([0x47, 0x47, 0x55, 0x46]) // "GGUF"
    }
}

// MARK: - 内置模型列表（unsloth/Hy-MT2-1.8B-GGUF 各量化档）

extension ModelProfile {
    static let repoPath = "unsloth/Hy-MT2-1.8B-GGUF"

    static let available: [ModelProfile] = [
        ModelProfile(
            id: "hy-mt2-1.8b-iq2-m",
            name: "IQ2_M (690MB)",
            repoPath: repoPath,
            fileName: "Hy-MT2-1.8B-UD-IQ2_M.gguf",
            sizeBytes: 722_666_176,
            template: .hyMT2,
            endpoint: .chatCompletions,
            sampling: SamplingParams(temperature: 0.7, topP: 0.6, topK: 20, repetitionPenalty: 1.05, maxTokens: 4096),
            languages: ModelProfile.allLanguages
        ),
        ModelProfile(
            id: "hy-mt2-1.8b-q3-k-m",
            name: "Q3_K_M (907MB)",
            repoPath: repoPath,
            fileName: "Hy-MT2-1.8B-Q3_K_M.gguf",
            sizeBytes: 951_022_560,
            template: .hyMT2,
            endpoint: .chatCompletions,
            sampling: SamplingParams(temperature: 0.7, topP: 0.6, topK: 20, repetitionPenalty: 1.05, maxTokens: 4096),
            languages: ModelProfile.allLanguages
        ),
        ModelProfile(
            id: "hy-mt2-1.8b-q4-k-m",
            name: "Q4_K_M (1.08GB)",
            repoPath: repoPath,
            fileName: "Hy-MT2-1.8B-Q4_K_M.gguf",
            sizeBytes: 1_133_081_568,
            template: .hyMT2,
            endpoint: .chatCompletions,
            sampling: SamplingParams(temperature: 0.7, topP: 0.6, topK: 20, repetitionPenalty: 1.05, maxTokens: 4096),
            languages: ModelProfile.allLanguages
        ),
    ]

    /// 默认模型（IQ2_M）
    static let hyMT2 = available[0]
}

// MARK: - 官方语言表（全称）

extension ModelProfile {
    static let allLanguages: [Language] = [
        Language(code: "zh", english: "Chinese", chinese: "中文"),
        Language(code: "en", english: "English", chinese: "英语"),
        Language(code: "fr", english: "French", chinese: "法语"),
        Language(code: "pt", english: "Portuguese", chinese: "葡萄牙语"),
        Language(code: "es", english: "Spanish", chinese: "西班牙语"),
        Language(code: "ja", english: "Japanese", chinese: "日语"),
        Language(code: "tr", english: "Turkish", chinese: "土耳其语"),
        Language(code: "ru", english: "Russian", chinese: "俄语"),
        Language(code: "ar", english: "Arabic", chinese: "阿拉伯语"),
        Language(code: "ko", english: "Korean", chinese: "韩语"),
        Language(code: "th", english: "Thai", chinese: "泰语"),
        Language(code: "it", english: "Italian", chinese: "意大利语"),
        Language(code: "de", english: "German", chinese: "德语"),
        Language(code: "vi", english: "Vietnamese", chinese: "越南语"),
        Language(code: "ms", english: "Malay", chinese: "马来语"),
        Language(code: "id", english: "Indonesian", chinese: "印度尼西亚语"),
        Language(code: "tl", english: "Tagalog", chinese: "他加禄语"),
        Language(code: "hi", english: "Hindi", chinese: "印地语"),
        Language(code: "pl", english: "Polish", chinese: "波兰语"),
        Language(code: "cs", english: "Czech", chinese: "捷克语"),
        Language(code: "nl", english: "Dutch", chinese: "荷兰语"),
        Language(code: "km", english: "Khmer", chinese: "高棉语"),
        Language(code: "my", english: "Burmese", chinese: "缅甸语"),
        Language(code: "fa", english: "Persian", chinese: "波斯语"),
        Language(code: "gu", english: "Gujarati", chinese: "古吉拉特语"),
        Language(code: "ur", english: "Urdu", chinese: "乌尔都语"),
        Language(code: "te", english: "Telugu", chinese: "泰卢固语"),
        Language(code: "mr", english: "Marathi", chinese: "马拉地语"),
        Language(code: "he", english: "Hebrew", chinese: "希伯来语"),
        Language(code: "bn", english: "Bengali", chinese: "孟加拉语"),
        Language(code: "ta", english: "Tamil", chinese: "泰米尔语"),
        Language(code: "uk", english: "Ukrainian", chinese: "乌克兰语"),
        Language(code: "bo", english: "Tibetan", chinese: "藏语"),
        Language(code: "kk", english: "Kazakh", chinese: "哈萨克语"),
        Language(code: "mn", english: "Mongolian", chinese: "蒙古语"),
        Language(code: "ug", english: "Uyghur", chinese: "维吾尔语"),
    ]
}
