import Foundation
import SwiftUI

/// One key on the terminal's extra-keys bar.
///
/// The bar exists to supply the characters and actions a phone keyboard cannot
/// produce, so which keys are useful depends on what the user is doing — someone
/// running `apk` wants different keys from someone editing a script. Each key is
/// therefore a named, individually hideable item rather than a hard-coded row.
enum TerminalKey: String, CaseIterable, Identifiable, Codable {
    case interrupt
    case escape
    case tab
    case previous
    case next
    case dash
    case dot
    case slash
    case colon
    case bang
    case pipe
    case components
    case files
    case paste
    case hideKeyboard

    var id: String { rawValue }

    /// The title shown in the configuration list.
    var title: String {
        switch self {
        case .interrupt: return "Interrupt (Ctrl-C)"
        case .escape: return "Escape"
        case .tab: return "Tab"
        case .previous: return "Previous command"
        case .next: return "Next command"
        case .dash: return "Minus"
        case .dot: return "Period"
        case .slash: return "Slash"
        case .colon: return "Colon"
        case .bang: return "Exclamation mark"
        case .pipe: return "Pipe"
        case .components: return "Components"
        case .files: return "List files"
        case .paste: return "Paste"
        case .hideKeyboard: return "Hide keyboard"
        }
    }

    /// What the key shows. Punctuation and the history arrows are their own glyph;
    /// the rest are SF Symbols.
    var label: String {
        switch self {
        case .previous: return "↑"
        case .next: return "↓"
        case .dash: return "-"
        case .dot: return "."
        case .slash: return "/"
        case .colon: return ":"
        case .bang: return "!"
        case .pipe: return "|"
        default: return ""
        }
    }

    var symbol: String? {
        switch self {
        case .interrupt: return "control"
        case .escape: return "escape"
        case .tab: return "arrow.right.to.line.alt"
        case .components: return "wrench.and.screwdriver"
        case .files: return "folder"
        case .paste: return "doc.on.clipboard"
        case .hideKeyboard: return "keyboard.chevron.compact.down"
        default: return nil
        }
    }

    /// A key that cannot be turned off.
    ///
    /// Hide Keyboard is pinned: without it there is no way back to the terminal's
    /// screen once the keyboard covers it, so a mis-tap in the configuration list
    /// could leave the terminal unusable. Every other key is a preference.
    var isPinned: Bool { self == .hideKeyboard }

    /// Grouping for the configuration list, so related keys read together.
    static let groups: [(title: String, keys: [TerminalKey])] = [
        ("Control", [.interrupt, .escape, .tab]),
        ("History", [.previous, .next]),
        ("Punctuation", [.dash, .dot, .slash, .colon, .bang, .pipe]),
        ("Actions", [.components, .files, .paste]),
        ("Always shown", [.hideKeyboard]),
    ]
}

/// Which keys the terminal shows, persisted between launches.
///
/// Stored as the set of *hidden* keys rather than the visible ones, so a key added
/// in a future version shows up by default instead of being silently absent from
/// an existing user's bar.
@MainActor
final class TerminalKeyConfiguration: ObservableObject {
    @Published private(set) var hidden: Set<TerminalKey> = []
    @Published private(set) var order: [TerminalKey] = []

    private static let defaultsKey = "org.xforge.terminal.hiddenKeys"
    private static let orderKey = "org.xforge.terminal.keyOrder"

    init() {
        let raw = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        hidden = Set(raw.compactMap(TerminalKey.init(rawValue:)))
        let saved = (UserDefaults.standard.stringArray(forKey: Self.orderKey) ?? [])
            .compactMap(TerminalKey.init(rawValue:))
        let defaults = TerminalKey.groups.flatMap(\.keys)
        order = saved + defaults.filter { !saved.contains($0) }
    }

    /// Whether a key is shown. Pinned keys ignore the stored preference.
    func isVisible(_ key: TerminalKey) -> Bool {
        if key.isPinned { return true }
        return !hidden.contains(key)
    }

    func setVisible(_ visible: Bool, for key: TerminalKey) {
        guard !key.isPinned else { return }
        if visible { hidden.remove(key) } else { hidden.insert(key) }
        save()
    }

    func toggle(_ key: TerminalKey) {
        setVisible(!isVisible(key), for: key)
    }

    /// Restore every key.
    func resetToDefaults() {
        hidden = []
        order = TerminalKey.groups.flatMap(\.keys)
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        order.move(fromOffsets: source, toOffset: destination)
        save()
    }

    var visibleKeys: [TerminalKey] { order.filter(isVisible) }

    private func save() {
        UserDefaults.standard.set(hidden.map(\.rawValue).sorted(), forKey: Self.defaultsKey)
        UserDefaults.standard.set(order.map(\.rawValue), forKey: Self.orderKey)
    }
}
