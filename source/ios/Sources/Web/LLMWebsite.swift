import Foundation

/// Official website destinations only. Transcripts are never included in their URLs.
enum LLMWebsite: String, CaseIterable, Identifiable, Sendable {
    case deepseek, chatgpt, claude, gemini, kimi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deepseek: "DeepSeek"
        case .chatgpt: "ChatGPT"
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .kimi: "Kimi"
        }
    }

    var url: URL {
        let address: String
        switch self {
        case .deepseek: address = "https://chat.deepseek.com/"
        case .chatgpt: address = "https://chatgpt.com/"
        case .claude: address = "https://claude.ai/"
        case .gemini: address = "https://gemini.google.com/"
        case .kimi: address = "https://www.kimi.com/"
        }
        return URL(string: address)!
    }

    static func saved(_ raw: String) -> LLMWebsite {
        LLMWebsite(rawValue: raw) ?? .deepseek
    }
}
