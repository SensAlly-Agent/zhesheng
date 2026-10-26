import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The look of the app: the magma colormap of log-mel spectrograms gives the accents, the scope stays a dark
/// instrument screen in both appearances, and every motion is one of a few named springs.
enum Palette {
    static let ember = Color(light: 0xC9631A, dark: 0xFFA45F)
    static let plum = Color(light: 0xB02C64, dark: 0xDD4A7C)
    static let ok = Color(light: 0x0F9569, dark: 0x5AD6A5)
    static let rec = Color(light: 0xDD322B, dark: 0xFF5B55)
    static let card = Color(light: 0xF6F5FA, dark: 0x1A1A28)
    static let well = Color(light: 0xECEAF2, dark: 0x11111B)
    static let raised = Color(light: 0xFFFFFF, dark: 0x22222F)
    static let line = Color(light: 0x2C245A, dark: 0xB2ACDE).opacity(0.14)
    static let faint = Color(light: 0xA6A2B9, dark: 0x5C5874)
    /// The scope is the same dark screen in both appearances.
    static let scope = Color(hex: 0x07060C)
    static let scopeText = Color(hex: 0xEDE8F6)
    static let ctaGradient = LinearGradient(colors: [Color(hex: 0xDD4A7C), Color(hex: 0xFFA45F)],
                                            startPoint: .leading, endPoint: .trailing)
}

enum Motion {
    static let snap = Animation.spring(response: 0.32, dampingFraction: 0.86)
    static let bounce = Animation.spring(response: 0.45, dampingFraction: 0.55)
    static let soft = Animation.spring(response: 0.7, dampingFraction: 0.92)
    static let wipe = Animation.easeInOut(duration: 0.9)
}

enum Typeface {
    /// The transcript reads like typeset text; Songti falls back to the system face where it is missing.
    static func serif(_ size: CGFloat, weight: Font.Weight = .medium) -> Font { .custom("Songti SC", size: size).weight(weight) }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

/// matplotlib's magma, the usual colormap of a spectrogram.
enum Magma {
    private static let stops: [(Double, Double, Double, Double)] = [
        (0, 0, 0, 4), (0.13, 28, 16, 68), (0.25, 79, 18, 123), (0.38, 129, 37, 129), (0.5, 181, 54, 122),
        (0.63, 229, 80, 100), (0.75, 251, 135, 97), (0.88, 254, 194, 135), (1, 252, 253, 191),
    ]
    /// 256 RGB triples.
    static let table: [UInt8] = {
        var out = [UInt8](repeating: 0, count: 256 * 3)
        for i in 0..<256 {
            let v = Double(i) / 255
            var j = 0
            while j < stops.count - 2 && v > stops[j + 1].0 { j += 1 }
            let a = stops[j], b = stops[j + 1], f = (v - a.0) / (b.0 - a.0)
            out[i * 3] = UInt8(a.1 + (b.1 - a.1) * f)
            out[i * 3 + 1] = UInt8(a.2 + (b.2 - a.2) * f)
            out[i * 3 + 2] = UInt8(a.3 + (b.3 - a.3) * f)
        }
        return out
    }()

    static func color(_ v: Double) -> Color {
        let i = max(0, min(255, Int(v * 255))) * 3
        return Color(red: Double(table[i]) / 255, green: Double(table[i + 1]) / 255, blue: Double(table[i + 2]) / 255)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    init(light: UInt32, dark: UInt32) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            NSColor(Color(hex: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light))
        })
        #else
        self.init(uiColor: UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
        #endif
    }
}

/// A simple wrapping layout (for the before/after example, one view per character).
struct FlowLayout: Layout {
    var spacing: CGFloat = 0
    var lineSpacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y + row.height - size.height),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0; var y: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if rows[rows.count - 1].width + size.width > width, !rows[rows.count - 1].items.isEmpty {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + lineSpacing))
            }
            rows[rows.count - 1].items.append(index)
            rows[rows.count - 1].width += size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

/// A card surface: fill, hairline, radius.
struct CardStyle: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line))
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardStyle(padding: padding)) }
}
