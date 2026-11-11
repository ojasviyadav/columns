// Reading settings: the model every window follows, and the "Aa" popover that edits it
// (columns, text size, theme, font), in the manner of the appearance popover in Books.
import AppKit
import Observation
import SwiftUI

enum Theme: String, CaseIterable, Identifiable {
    case system, light, sepia, dark
    var id: Self { self }
    var name: String { rawValue.capitalized }
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light, .sepia: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
    // Page colours; they match the themes in index.html.
    var page: NSColor {
        switch self {
        case .system: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? Theme.dark.page : Theme.light.page }
        case .light: NSColor(srgbRed: 0.984, green: 0.984, blue: 0.980, alpha: 1)
        case .sepia: NSColor(srgbRed: 0.957, green: 0.925, blue: 0.847, alpha: 1)
        case .dark: NSColor(srgbRed: 0.110, green: 0.110, blue: 0.118, alpha: 1)
        }
    }
    // Text colours, also from index.html; the swatches show a sample of the text in each theme.
    var ink: NSColor {
        switch self {
        case .system, .light: NSColor(srgbRed: 0.114, green: 0.114, blue: 0.122, alpha: 1)
        case .sepia: NSColor(srgbRed: 0.231, green: 0.184, blue: 0.133, alpha: 1)
        case .dark: NSColor(srgbRed: 0.894, green: 0.894, blue: 0.902, alpha: 1)
        }
    }
}

enum Family: String, CaseIterable, Identifiable {
    case system, libron
    var id: Self { self }
    var name: String { self == .system ? "System" : "Libron" }
    func font(_ size: CGFloat) -> Font { self == .system ? .system(size: size) : .custom("Libron-Regular", size: size) }
}

@MainActor @Observable
final class ReadingSettings {
    static let shared = ReadingSettings()
    static let defaultFontSize = 16, minFontSize = 8, maxFontSize = 48

    var columns = Prefs.columns {
        didSet { Prefs.columns = columns; showColumns() }
    }
    // Resting the pointer on a column count shows it at once without saving it; moving off goes back to the
    // saved count. The short delay keeps a sweep across the row from flashing every count on the way.
    private var preview: Int? {
        didSet { if preview != oldValue { showColumns() } }
    }
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    func hover(_ n: Int?) {
        hoverTask?.cancel()
        hoverTask = Task {
            try? await Task.sleep(for: .milliseconds(110))
            if !Task.isCancelled { preview = n }
        }
    }
    private func showColumns() { let n = preview ?? columns, now = byKeyboard(); Reader.all.forEach { $0.call("setColumns", n, now) } }
    var fontSize = Prefs.fontSize {
        didSet { Prefs.fontSize = fontSize; Reader.all.forEach { $0.call("setFont", fontSize) } }
    }
    var theme = Prefs.theme {
        didSet { Prefs.theme = theme; Reader.all.forEach { $0.applyTheme() } }
    }
    var family = Prefs.family {
        didSet { Prefs.family = family; Reader.all.forEach { $0.call("setFamily", family.rawValue) } }
    }
    var bigDots = Prefs.bigDots {
        didSet { Prefs.bigDots = bigDots; Reader.all.forEach { $0.call("setDots", bigDots) } }
    }

    var boldStarts = Prefs.boldStarts {
        didSet { Prefs.boldStarts = boldStarts; Reader.all.forEach { $0.call("setBoldStarts", boldStarts) } }
    }

    func resize(_ delta: Int) { fontSize = min(Self.maxFontSize, max(Self.minFontSize, fontSize + delta)) }
}

// What the popover's window can do now, so Collapse All and Expand All are off when they would change nothing.
@MainActor @Observable
final class FoldState {
    var canCollapse = false
    var canExpand = false
}

struct SettingsView: View {
    @Bindable var s: ReadingSettings
    var folds = FoldState()
    var fold: (Bool) -> Void = { _ in }  // collapse (true) or expand (false) every section of this document

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(1...Prefs.maxColumns, id: \.self) { n in
                    Button { s.columns = n } label: { ColumnsGlyph(count: n).frame(maxWidth: .infinity, minHeight: 34) }
                        .buttonStyle(Choice(selected: s.columns == n))
                        .onHover { s.hover($0 ? n : nil) }
                        .help(n == 1 ? "1 column (⌘1)" : "\(n) columns (⌘\(n))")
                        .accessibilityLabel(n == 1 ? "1 column" : "\(n) columns")
                }
            }
            Divider()
            HStack(spacing: 6) {
                Button { s.resize(-1) } label: { Image(systemName: "textformat.size.smaller").frame(maxWidth: .infinity, minHeight: 34) }
                    .buttonStyle(Choice(selected: false)).disabled(s.fontSize <= ReadingSettings.minFontSize)
                    .help("Smaller text (⌘−)").accessibilityLabel("Smaller text")
                // The size, with a way back to the actual size that shows only when the size was changed.
                Text("\(s.fontSize) pt").monospacedDigit().contentTransition(.numericText(value: Double(s.fontSize)))
                    .foregroundStyle(.secondary).accessibilityLabel("Text size \(s.fontSize) points")
                    .frame(width: 92, height: 34)
                    .overlay(alignment: .trailing) {
                        let changed = s.fontSize != ReadingSettings.defaultFontSize
                        Button { s.fontSize = ReadingSettings.defaultFontSize } label: {
                            Image(systemName: "arrow.counterclockwise").font(.caption.weight(.semibold)).frame(width: 24, height: 24)
                        }
                        .buttonStyle(Choice(selected: false)).opacity(changed ? 1 : 0).disabled(!changed)
                        .help("Actual size (⌘0)").accessibilityLabel("Actual size")
                    }
                Button { s.resize(1) } label: { Image(systemName: "textformat.size.larger").frame(maxWidth: .infinity, minHeight: 34) }
                    .buttonStyle(Choice(selected: false)).disabled(s.fontSize >= ReadingSettings.maxFontSize)
                    .help("Bigger text (⌘+)").accessibilityLabel("Bigger text")
            }
            Divider()
            HStack(spacing: 0) {
                ForEach(Theme.allCases) { t in
                    Button { s.theme = t } label: {
                        VStack(spacing: 6) {
                            Swatch(theme: t, selected: s.theme == t)
                            Text(t.name).font(.caption).foregroundStyle(s.theme == t ? .primary : .secondary)
                        }
                        .frame(maxWidth: .infinity).contentShape(Rectangle())
                    }
                    .buttonStyle(Pressed())
                    .help("\(t.name) theme")
                    .accessibilityLabel("\(t.name) theme").accessibilityAddTraits(s.theme == t ? .isSelected : [])
                }
            }
            Divider()
            HStack(spacing: 6) {
                ForEach(Family.allCases) { f in
                    Button { s.family = f } label: {
                        VStack(spacing: 2) {
                            Text("Aa").font(f.font(24))
                            Text(f.name).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 62)
                    }
                    .buttonStyle(Choice(selected: s.family == f))
                    .help("\(f.name) font").accessibilityLabel("\(f.name) font")
                }
            }
            Divider()
            HStack(spacing: 6) {
                Button { fold(true) } label: { Label("Collapse All", systemImage: "chevron.right").frame(maxWidth: .infinity, minHeight: 30) }
                    .buttonStyle(Choice(selected: false)).disabled(!folds.canCollapse).help("Collapse every section (⌥⇧⌘←)")
                Button { fold(false) } label: { Label("Expand All", systemImage: "chevron.down").frame(maxWidth: .infinity, minHeight: 30) }
                    .buttonStyle(Choice(selected: false)).disabled(!folds.canExpand).help("Expand every section (⌥⇧⌘→)")
            }
            .font(.callout)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bigger dots")
                    Text("The dots that show where the text continues").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Bigger dots", isOn: $s.bigDots).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bold word starts")
                    Text("The first letters of each word in bold").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Bold word starts", isOn: $s.boldStarts).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 300)
        .onDisappear { s.hover(nil) }  // closing the panel mid-preview returns to the saved count
        // Choices slide into place and the size rolls, quickly enough to read as feedback, not decoration.
        .animation(.snappy(duration: 0.2), value: s.columns)
        .animation(.snappy(duration: 0.2), value: s.fontSize)
        .animation(.snappy(duration: 0.2), value: s.theme)
        .animation(.snappy(duration: 0.2), value: s.family)
    }
}

// N slim bars: one per column, so the row reads without labels.
struct ColumnsGlyph: View {
    let count: Int
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { _ in RoundedRectangle(cornerRadius: 1.5).frame(height: 15) }
        }
        .frame(width: 26)
    }
}

struct Swatch: View {
    let theme: Theme
    let selected: Bool
    var body: some View {
        ZStack {
            if theme == .system {  // half light, half dark, each with its own text colour
                Circle().fill(Color(nsColor: Theme.light.page))
                Text("Aa").foregroundStyle(Color(nsColor: Theme.light.ink))
                Group {
                    Circle().fill(Color(nsColor: Theme.dark.page))
                    Text("Aa").foregroundStyle(Color(nsColor: Theme.dark.ink))
                }
                .mask(HStack(spacing: 0) { Color.clear; Color.black })
            } else {
                Circle().fill(Color(nsColor: theme.page))
                Text("Aa").foregroundStyle(Color(nsColor: theme.ink))
            }
            Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
        }
        .font(.system(size: 13, weight: .medium))
        .frame(width: 34, height: 34)
        .padding(3)
        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2).opacity(selected ? 1 : 0))
    }
}

// A plain button that gives a little under the press.
struct Pressed: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.95 : 1).animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// A quiet tile: tinted when chosen, a faint lift on hover.
struct Choice: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View { Tile(configuration: configuration, selected: selected) }

    struct Tile: View {
        let configuration: Configuration
        let selected: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .opacity(enabled ? 1 : 0.35)
                .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.75))
                .background(RoundedRectangle(cornerRadius: 8).fill(fill))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(selected ? 0.6 : 0), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .scaleEffect(configuration.isPressed && enabled ? 0.97 : 1)  // the press is felt at once
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { hover = $0 }
        }
        private var fill: Color {
            if selected { return Color.accentColor.opacity(0.14) }
            if configuration.isPressed { return Color.primary.opacity(0.12) }
            return Color.primary.opacity(hover && enabled ? 0.08 : 0.04)
        }
    }
}
