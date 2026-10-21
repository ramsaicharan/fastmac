import SwiftUI
import AppKit

/// FastMac's shared visual language. Views use these tokens instead of literal
/// sizes and colours, so every screen shares one spacing scale, one type ramp,
/// three corner radii, one set of semantic colours and one motion curve.
enum DS {
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Radius {
        /// Controls, chips and icon plates.
        static let sm: CGFloat = 8
        /// Rows and compact tiles.
        static let md: CGFloat = 12
        /// Cards, panels and the menu bar popup.
        static let lg: CGFloat = 16
    }

    enum Palette {
        static let accent = dynamic(light: rgb(0.15, 0.42, 0.98), dark: rgb(0.16, 0.52, 1.00))
        /// Page background behind cards.
        static let canvas = dynamic(light: rgb(0.962, 0.962, 0.972), dark: rgb(0.118, 0.118, 0.128))
        /// Card fill on the canvas.
        static let surface = dynamic(light: rgb(1, 1, 1), dark: rgb(0.170, 0.170, 0.182))
        /// Card fill while hovered.
        static let surfaceHover = dynamic(light: rgb(0.985, 0.988, 1), dark: rgb(0.205, 0.205, 0.220))
        static let hairline = dynamic(light: NSColor(white: 0, alpha: 0.075), dark: NSColor(white: 1, alpha: 0.085))
        static let good = dynamic(light: rgb(0.13, 0.65, 0.33), dark: rgb(0.26, 0.82, 0.45))
        static let warning = dynamic(light: rgb(0.92, 0.50, 0.00), dark: rgb(1.00, 0.64, 0.20))
        static let critical = dynamic(light: rgb(0.86, 0.20, 0.18), dark: rgb(1.00, 0.38, 0.35))
        /// Translucent fills that also read correctly over vibrancy.
        static let fill = Color.primary.opacity(0.05)
        static let fillStrong = Color.primary.opacity(0.09)

        private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
            NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
        private static func dynamic(light: NSColor, dark: NSColor) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua,
                                            .accessibilityHighContrastVibrantDark]) == nil ? light : dark
            })
        }
    }

    enum Motion {
        /// Hover and press feedback.
        static let quick = Animation.easeOut(duration: 0.14)
        /// Value and layout changes.
        static let standard = Animation.smooth(duration: 0.35)
    }
}

extension Font {
    static let dsLargeTitle = Font.system(size: 28, weight: .bold)
    static let dsTitle = Font.system(size: 20, weight: .semibold)
    static let dsHeadline = Font.system(size: 14, weight: .semibold)
    static let dsBody = Font.system(size: 13)
    static let dsBodyEmphasis = Font.system(size: 13, weight: .medium)
    static let dsCaption = Font.system(size: 11)
    static let dsCaptionEmphasis = Font.system(size: 11, weight: .medium)
    static let dsEyebrow = Font.system(size: 10, weight: .semibold)
    static let dsMetric = Font.system(size: 28, weight: .semibold, design: .rounded)
    static let dsMetricCompact = Font.system(size: 20, weight: .semibold, design: .rounded)
}

extension HealthStatus {
    var color: Color {
        switch self {
        case .comfortable: DS.Palette.good
        case .attention: DS.Palette.warning
        case .critical: DS.Palette.critical
        case .unknown: .secondary
        }
    }
}

// MARK: - Surfaces

extension View {
    /// A static card on the page canvas.
    func dsCard(padding: CGFloat = DS.Space.md) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).strokeBorder(DS.Palette.hairline))
            .shadow(color: .black.opacity(0.035), radius: 1.5, y: 1)
    }

    /// Numbers that roll instead of jumping when a reading changes.
    func dsNumeric<V: Equatable>(_ value: V) -> some View {
        self.monospacedDigit()
            .contentTransition(.numericText())
            .animation(DS.Motion.standard, value: value)
    }
}

/// A whole card that navigates. Lifts its fill and border on hover.
struct DSCardButtonStyle: ButtonStyle {
    var padding: CGFloat = DS.Space.md
    func makeBody(configuration: Configuration) -> some View { CardBody(configuration: configuration, padding: padding) }

    private struct CardBody: View {
        let configuration: Configuration
        let padding: CGFloat
        @State private var hovering = false
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
            configuration.label
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(hovering ? DS.Palette.surfaceHover : DS.Palette.surface, in: shape)
                .overlay(shape.strokeBorder(hovering ? DS.Palette.accent.opacity(0.35) : DS.Palette.hairline))
                .shadow(color: .black.opacity(hovering ? 0.07 : 0.035), radius: hovering ? 6 : 1.5, y: hovering ? 2 : 1)
                .scaleEffect(configuration.isPressed ? 0.988 : 1)
                .contentShape(shape)
                .onHover { hovering = $0 }
                .animation(DS.Motion.quick, value: hovering)
                .animation(DS.Motion.quick, value: configuration.isPressed)
        }
    }
}

/// A translucent tile for use over vibrancy (the menu bar popup).
struct DSTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { TileBody(configuration: configuration) }

    private struct TileBody: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
            configuration.label
                .background(hovering ? DS.Palette.fillStrong : DS.Palette.fill, in: shape)
                .overlay(shape.strokeBorder(DS.Palette.hairline))
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .contentShape(shape)
                .onHover { hovering = $0 }
                .animation(DS.Motion.quick, value: hovering)
                .animation(DS.Motion.quick, value: configuration.isPressed)
        }
    }
}

// MARK: - Buttons

struct DSButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    var kind: Kind = .secondary
    var fullWidth = false
    var compact = false
    var tint: Color = DS.Palette.accent

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind, fullWidth: fullWidth, compact: compact, tint: tint)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let kind: Kind
        let fullWidth: Bool
        let compact: Bool
        let tint: Color
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
            configuration.label
                .font(compact ? .dsCaptionEmphasis : .dsBodyEmphasis)
                .lineLimit(1)
                .padding(.horizontal, compact ? DS.Space.xs + 2 : DS.Space.sm + 2)
                .padding(.vertical, compact ? 4 : 7)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .foregroundStyle(foreground)
                .background(background, in: shape)
                .overlay {
                    if kind == .primary {
                        shape.fill(LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: .bottom))
                    }
                }
                .contentShape(shape)
                .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
                .onHover { hovering = $0 && isEnabled }
                .animation(DS.Motion.quick, value: hovering)
        }

        private var foreground: Color {
            switch kind {
            case .primary: .white
            case .secondary: .primary
            case .quiet: tint
            }
        }

        private var background: Color {
            switch kind {
            case .primary: hovering ? tint.opacity(0.88) : tint
            case .secondary: hovering ? Color.primary.opacity(0.13) : DS.Palette.fillStrong
            case .quiet: hovering ? tint.opacity(0.12) : .clear
            }
        }
    }
}

/// Square icon-only button for toolbars and headers.
struct DSIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    func makeBody(configuration: Configuration) -> some View { IconButtonBody(configuration: configuration, size: size) }

    private struct IconButtonBody: View {
        let configuration: Configuration
        let size: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: size, height: size)
                .background(hovering ? DS.Palette.fillStrong : .clear,
                            in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                .contentShape(Rectangle())
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
                .onHover { hovering = $0 && isEnabled }
                .animation(DS.Motion.quick, value: hovering)
        }
    }
}

// MARK: - Small components

/// A tinted square holding an SF Symbol.
struct IconPlate: View {
    let symbol: String
    var tint: Color = DS.Palette.accent
    var size: CGFloat = 32
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A coloured dot that gently pulses while something is live.
struct StatusDot: View {
    let color: Color
    var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        ZStack {
            if pulsing && !reduceMotion {
                Circle().fill(color.opacity(0.35))
                    .scaleEffect(expanded ? 2.4 : 1).opacity(expanded ? 0 : 1)
            }
            Circle().fill(color)
        }
        .frame(width: 7, height: 7)
        .onAppear {
            guard pulsing && !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { expanded = true }
        }
        .accessibilityHidden(true)
    }
}

/// A rounded label with a status dot, e.g. "● Live".
struct StatusPill: View {
    let text: String
    let color: Color
    var pulsing = false
    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: color, pulsing: pulsing)
            Text(text).font(.dsCaptionEmphasis)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(DS.Palette.fill, in: Capsule())
    }
}

/// Segmented level indicator for ordinal signals such as memory pressure.
struct LevelMeter: View {
    let level: Int
    let steps: Int
    let tint: Color
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<steps, id: \.self) { index in
                Capsule()
                    .fill(index < level ? tint : DS.Palette.fillStrong)
                    .frame(height: 6)
            }
        }
        .animation(DS.Motion.standard, value: level)
        .accessibilityHidden(true)
    }
}

/// Continuous bar for fractions such as storage used.
struct MeterBar: View {
    let fraction: Double?
    let tint: Color
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Palette.fillStrong)
                if let fraction, fraction.isFinite {
                    Capsule().fill(tint)
                        .frame(width: max(height, proxy.size.width * min(1, max(0, fraction))))
                }
            }
        }
        .frame(height: height)
        .animation(DS.Motion.standard, value: fraction)
        .accessibilityHidden(true)
    }
}

/// An ⓘ that reveals supporting detail on click, so pages lead with the
/// reading and keep caveats one step away instead of in every paragraph.
struct InfoButton: View {
    let text: String
    @State private var showing = false
    init(_ text: String) { self.text = text }
    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .help(text)
        .accessibilityLabel("More information")
        .accessibilityHint(text)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            Text(text).font(.dsCaption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(DS.Space.md)
        }
    }
}

/// Section title with an optional trailing accessory.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.dsHeadline)
            Spacer()
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
}

// MARK: - Vibrancy

/// Behind-window blur, as used by Control Center and menu bar extras.
/// ImageRenderer cannot draw this, so it belongs only in live window hosts.
struct VibrancyBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var cornerRadius: CGFloat = DS.Radius.lg

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        // The popup is a non-activating panel; keep the active look regardless.
        view.state = .active
        view.maskImage = Self.mask(radius: cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }

    private static func mask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
