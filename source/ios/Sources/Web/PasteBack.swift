import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// "贴回结果": the proofread text the person copied from the AI website comes back into the app. The clipboard is
/// checked first: nothing on it, or still the prompt the app copied for the site (the answer was not copied yet), is
/// refused with the reason; a code fence or the prompt's quote lines around the answer are taken off.
enum PasteBack {
    enum Check: Equatable {
        case ready(String)
        case empty
        case stillPrompt
        case unchanged
    }

    /// The prompt's first line: an answer never starts with it, the copied prompt always does.
    static let promptHead = String(ProofreadingPrompt.prefix.prefix { $0 != "\n" })

    static func check(_ clipboard: String?, current: String) -> Check {
        let text = clean(clipboard ?? "")
        guard !text.isEmpty else { return .empty }
        if text.contains(promptHead) { return .stillPrompt }
        if text == current.trimmingCharacters(in: .whitespacesAndNewlines) { return .unchanged }
        return .ready(text)
    }

    /// The answer without the space around it and without lines that only wrap it: a code fence (```, ```text)
    /// or the prompt's quote marks (’‘’, ‘’‘, ''').
    static func clean(_ raw: String) -> String {
        var lines = raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
        func wraps(_ line: String) -> Bool {
            let line = line.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("```") || (line.count == 3 && line.allSatisfy { "’‘'".contains($0) })
        }
        while let first = lines.first, wraps(first) { lines.removeFirst() }
        while let last = lines.last, wraps(last) { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    static func clipboardText() -> String? {
        #if os(macOS)
        NSPasteboard.general.string(forType: .string)
        #else
        UIPasteboard.general.string
        #endif
    }
}
