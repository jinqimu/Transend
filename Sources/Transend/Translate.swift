import Foundation

enum TranslateError: LocalizedError {
    case engineNotRunning
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .engineNotRunning: return "引擎未运行"
        case .badResponse(let msg): return "引擎返回异常：\(msg)"
        }
    }
}

/// 按 profile 构造提示词并流式调用本地 llama-server。
struct Translator {

    let engine: Engine
    let profile: ModelProfile

    @MainActor
    func stream(_ text: String, target: Language, chinesePrompt: Bool = false) -> AsyncThrowingStream<String, Error> {
        let baseURL = engine.baseURL
        let isRunning = engine.isRunning
        let prompt = profile.template.build(text: text, targetName: target.english, chinesePrompt: chinesePrompt)
        let endpoint = profile.endpoint
        let s = profile.sampling

        return AsyncThrowingStream { continuation in
            let task = Task {
                guard isRunning else {
                    continuation.finish(throwing: TranslateError.engineNotRunning)
                    return
                }

                var req = URLRequest(url: baseURL.appendingPathComponent(endpoint.path))
                req.httpMethod = "POST"
                req.timeoutInterval = 600
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")

                var body: [String: Any] = [
                    "temperature": s.temperature,
                    "top_p": s.topP,
                    "top_k": s.topK,
                    "repeat_penalty": s.repetitionPenalty,
                    "stream": true,
                ]
                switch endpoint {
                case .chatCompletions:
                    body["messages"] = [["role": "user", "content": prompt]]
                    body["max_tokens"] = s.maxTokens
                case .completion:
                    body["prompt"] = prompt
                    body["n_predict"] = s.maxTokens
                }
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)

                do {
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                        var errorBody = Data()
                        for try await b in bytes { errorBody.append(b) }
                        let bodyText = String(data: errorBody, encoding: .utf8) ?? ""
                        continuation.finish(throwing: TranslateError.badResponse("HTTP \(http.statusCode) \(bodyText)"))
                        return
                    }
                    // 按行解析 SSE；逐字节累积避免截断多字节字符
                    var lineBuffer = Data()
                    for try await byte in bytes {
                        lineBuffer.append(byte)
                        guard byte == 0x0A else { continue }
                        let line = String(data: lineBuffer, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        lineBuffer = Data()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" {
                            continuation.finish()
                            return
                        }
                        guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
                            continue
                        }
                        if let delta = Self.chatDelta(obj) ?? Self.completionDelta(obj), !delta.isEmpty {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// /v1/chat/completions: choices[0].delta.content
    private static func chatDelta(_ obj: [String: Any]) -> String? {
        guard let choices = obj["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any] else { return nil }
        return delta["content"] as? String
    }

    /// /completion: content（原生 SSE 增量）
    private static func completionDelta(_ obj: [String: Any]) -> String? {
        obj["content"] as? String
    }
}
