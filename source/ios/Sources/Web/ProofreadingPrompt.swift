import Foundation

/// Owner-approved prompt. Preserve the two spaces and curly delimiters exactly.
enum ProofreadingPrompt {
    static let prefix = "请处理下面这段语音转文字的原始识别  （直接输出结果，不需要任何解释说明）\n1.去除其中可能存在的错误，比如多音字以及其他的识别错误\n2.加入标点符号\n\n’‘’\n"
    static let suffix = "\n‘’‘"

    static func user(_ transcript: String) -> String { prefix + transcript + suffix }
}
