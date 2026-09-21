import SwiftUI

// MARK: - Colour

/// One terminal colour: an indexed palette entry (0–255) or a direct RGB value.
///
/// The guest is a real Linux system, so its programs emit whatever SGR codes
/// they like — `xtool`, `swift` and `apk` all colourise their output. Parsing
/// them here is what lets the terminal show a build the way it looks in a
/// desktop shell instead of a wall of escape sequences.
enum TerminalColor: Equatable, Hashable {
    case index(Int)
    case rgb(Int, Int, Int)

    /// The 16 ANSI colours, tuned for a dark terminal background.
    private static let palette: [Color] = [
        Color(red: 0.13, green: 0.13, blue: 0.15),   // 0 black
        Color(red: 0.87, green: 0.29, blue: 0.29),   // 1 red
        Color(red: 0.35, green: 0.82, blue: 0.44),   // 2 green
        Color(red: 0.93, green: 0.78, blue: 0.32),   // 3 yellow
        Color(red: 0.33, green: 0.58, blue: 0.96),   // 4 blue
        Color(red: 0.78, green: 0.47, blue: 0.96),   // 5 magenta
        Color(red: 0.32, green: 0.82, blue: 0.86),   // 6 cyan
        Color(red: 0.86, green: 0.88, blue: 0.91),   // 7 white
        Color(red: 0.38, green: 0.39, blue: 0.44),   // 8 bright black
        Color(red: 0.96, green: 0.42, blue: 0.42),   // 9 bright red
        Color(red: 0.47, green: 0.92, blue: 0.56),   // 10 bright green
        Color(red: 0.99, green: 0.86, blue: 0.42),   // 11 bright yellow
        Color(red: 0.47, green: 0.69, blue: 1.00),   // 12 bright blue
        Color(red: 0.87, green: 0.62, blue: 1.00),   // 13 bright magenta
        Color(red: 0.47, green: 0.92, blue: 0.96),   // 14 bright cyan
        Color(red: 0.99, green: 0.99, blue: 0.99),   // 15 bright white
    ]

    var color: Color {
        switch self {
        case .rgb(let r, let g, let b):
            return Color(red: Self.clamp(r), green: Self.clamp(g), blue: Self.clamp(b))
        case .index(let value):
            let n = max(0, min(value, 255))
            if n < 16 { return Self.palette[n] }
            if n < 232 {
                // The 6×6×6 colour cube.
                let i = n - 16
                func level(_ v: Int) -> Double {
                    v == 0 ? 0 : Double(55 + v * 40) / 255
                }
                return Color(red: level(i / 36),
                             green: level((i / 6) % 6),
                             blue: level(i % 6))
            }
            // The 24-step grey ramp.
            let v = Double(8 + (n - 232) * 10) / 255
            return Color(red: v, green: v, blue: v)
        }
    }

    private static func clamp(_ value: Int) -> Double {
        Double(max(0, min(value, 255))) / 255
    }
}

/// The attributes an SGR sequence can turn on.
struct TerminalStyle: Equatable {
    var foreground: TerminalColor?
    var background: TerminalColor?
    var bold = false
    var dim = false
    var italic = false
    var underline = false
    var inverse = false

    static let plain = TerminalStyle()

    /// The colour text is drawn in, with `inverse` resolved.
    var textColor: Color {
        if inverse { return (background ?? .index(0)).color }
        return (foreground ?? Self.defaultForeground).color
    }

    /// The colour behind the run, or nil for "the terminal's own background".
    var backgroundColor: Color? {
        if inverse { return (foreground ?? .index(15)).color }
        guard let background else { return nil }
        return background.color
    }

    /// Slightly warm off-white — the same default the iSH terminal uses.
    static let defaultForeground = TerminalColor.rgb(0xE6, 0xE9, 0xE6)
}

// MARK: - Cells, lines, and the buffer

/// One screen cell: a character and the style it was written with.
struct TerminalCell: Equatable {
    var character: Character
    var style: TerminalStyle
}

/// One completed line of the scrollback.
struct TerminalLine: Equatable {
    var cells: [TerminalCell] = []

    var isEmpty: Bool { cells.isEmpty }

    var text: String { String(cells.map(\.character)) }

    /// The line as an `AttributedString`, with runs of equal style merged.
    func attributedString(fontSize: CGFloat) -> AttributedString {
        guard !cells.isEmpty else { return AttributedString(" ") }

        var result = AttributedString()
        var index = 0
        while index < cells.count {
            let style = cells[index].style
            var text = ""
            while index < cells.count, cells[index].style == style {
                text.append(cells[index].character)
                index += 1
            }
            var run = AttributedString(text)
            run.foregroundColor = style.textColor
            if let background = style.backgroundColor {
                run.backgroundColor = background
            }
            if style.underline {
                run.underlineStyle = .single
            }
            if style.bold || style.italic || style.dim {
                var font = Font.system(size: fontSize, design: .monospaced)
                if style.bold { font = font.weight(.bold) }
                if style.italic { font = font.italic() }
                run.font = font
                if style.dim, let foreground = style.foreground {
                    // "Dim" has no monospaced-font equivalent; approximate it by
                    // blending the colour toward the background.
                    run.foregroundColor = foreground.color.opacity(0.65)
                } else if style.dim {
                    run.foregroundColor = style.textColor.opacity(0.65)
                }
            }
            result.append(run)
        }
        return result
    }
}

/// A very small terminal screen model.
///
/// It exists because the guest *is* a terminal program: a command that only
/// returns its output when it finishes still returns carriage-return rewrites
/// (curl's progress bar), backspaces and SGR colour. Feeding those through a
/// screen model instead of appending raw bytes is the difference between a log
/// view and a terminal.
///
/// It is a line/screen model, not a full emulator: cursor addressing, alternate
/// screens and scrolling regions are recognised and either honoured (`clear`,
/// `\r`, `\b`) or dropped, because XForge's bridge runs one command at a time
/// rather than hosting a live pty.
@MainActor
final class TerminalBuffer {
    /// Completed lines, oldest first.
    private(set) var lines: [TerminalLine] = []

    /// The line still being written to.
    private(set) var current = TerminalLine()
    private var cursor = 0

    /// Scrollback cap. The transcript is also persisted, so this is about the
    /// cost of keeping it on screen, not about losing history.
    var maxLines = 2000
    private let maxColumns = 512

    private var style = TerminalStyle()

    private enum EscapeState {
        case ground
        case escape
        case csi
        case osc
        case oscEscape
    }

    private var state: EscapeState = .ground
    private var csiParameters = ""
    private var pendingCarriageReturn = false

    var isAtStart: Bool { lines.isEmpty && current.isEmpty }

    /// Everything on screen plus the scrollback, as plain text.
    var plainText: String {
        (lines.map(\.text) + [current.text]).joined(separator: "\n")
    }

    func clear() {
        lines.removeAll()
        current = TerminalLine()
        cursor = 0
        style = .plain
        state = .ground
        csiParameters = ""
        pendingCarriageReturn = false
    }

    /// Feed a chunk of guest output through the screen model.
    func feed(_ text: String) {
        for character in text {
            switch state {
            case .ground:
                handleGround(character)
            case .escape:
                handleEscape(character)
            case .csi:
                handleCSI(character)
            case .osc:
                // OSC payload: skipped until BEL or ST.
                if character == "\u{07}" {
                    state = .ground
                } else if character == "\u{1b}" {
                    state = .oscEscape
                }
            case .oscEscape:
                state = character == "\\" ? .ground : .osc
            }
        }
    }

    /// Put a line on screen immediately (used for the terminal's own prompt and
    /// status lines, which are not guest output).
    func appendLine(_ text: String, style: TerminalStyle = .plain) {
        let saved = self.style
        self.style = style
        for character in text { write(character) }
        newline()
        self.style = saved
    }

    // MARK: - Ground state

    private func handleGround(_ character: Character) {
        switch character {
        case "\u{1b}":
            pendingCarriageReturn = false
            state = .escape
        case "\n", "\r\n":
            // Swift treats CR+LF as a *single* grapheme cluster, so a guest
            // program that emits Windows-style line endings delivers "\r\n" as
            // ONE Character — not as "\r" followed by "\n". Matching only "\n"
            // here would write that character into a cell and the line would
            // never break, turning a whole command's output into one line.
            pendingCarriageReturn = false
            newline()
        case "\r":
            // Held until the next character: "\r\n" is a newline, a bare "\r"
            // rewinds to column 0 so a progress bar can redraw its line.
            pendingCarriageReturn = true
        case "\u{08}":
            backspace()
        case "\t":
            applyPendingCarriageReturn()
            tab()
        default:
            // Remaining control characters (BEL, NUL, …) are not printable. A
            // grapheme can hold more than one scalar, so test all of them rather
            // than `asciiValue`, which is nil for anything multi-scalar.
            if character.unicodeScalars.allSatisfy({ $0.value < 0x20 }) { return }
            applyPendingCarriageReturn()
            write(character)
        }
    }

    private func applyPendingCarriageReturn() {
        guard pendingCarriageReturn else { return }
        pendingCarriageReturn = false
        cursor = 0
    }

    private func handleEscape(_ character: Character) {
        switch character {
        case "[":
            csiParameters = ""
            state = .csi
        case "]":
            state = .osc
        case "(", ")", "#", "%":
            // Two-byte sequences with a designator byte; stay in escape state
            // for one more character so the designator is swallowed too.
            state = .escape
        default:
            state = .ground
        }
    }

    private func handleCSI(_ character: Character) {
        // Parameter bytes, then a final byte in the range 0x40-0x7E.
        guard let ascii = character.asciiValue, ascii >= 0x40, ascii <= 0x7E else {
            if csiParameters.count < 32 { csiParameters.append(character) }
            return
        }
        state = .ground
        applyCSI(final: character, parameters: csiParameters)
        csiParameters = ""
    }

    private func applyCSI(final: Character, parameters: String) {
        switch final {
        case "m":
            applySGR(parameters)
        case "J":
            // Erase in display. Only the "whole screen" form is meaningful here
            // (the bridge has no cursor addressing), so `clear` and
            // `printf '\033[2J'` wipe the scrollback while the partial forms just
            // clear the line being written.
            if parameters.isEmpty || parameters == "2" {
                lines.removeAll()
                current = TerminalLine()
                cursor = 0
            } else if cursor < current.cells.count {
                current.cells.removeSubrange(cursor..<current.cells.count)
            }
        case "K":
            let mode = parameters.isEmpty ? "0" : parameters
            switch mode {
            case "2":
                current = TerminalLine()
                cursor = 0
            case "1":
                for index in 0..<min(cursor, current.cells.count) {
                    current.cells[index].character = " "
                }
            default:
                if cursor < current.cells.count {
                    current.cells.removeSubrange(cursor..<current.cells.count)
                }
            }
        case "A", "F":
            // Cursor up / previous line: ignored, this model has no cursor
            // addressing. Treated as a no-op rather than dropping text.
            break
        default:
            break
        }
    }

    private func applySGR(_ parameters: String) {
        let parts = parameters.split(separator: ";", omittingEmptySubsequences: false)
        var index = 0
        func parameter(_ offset: Int) -> Int? {
            guard index + offset < parts.count else { return nil }
            return Int(parts[index + offset])
        }
        while index < parts.count {
            let value = Int(parts[index]) ?? 0
            switch value {
            case 0:
                style = .plain
            case 1:
                style.bold = true
            case 2:
                style.dim = true
            case 3:
                style.italic = true
            case 4:
                style.underline = true
            case 7:
                style.inverse = true
            case 21, 22:
                style.bold = false
                style.dim = false
            case 23:
                style.italic = false
            case 24:
                style.underline = false
            case 27:
                style.inverse = false
            case 30...37:
                style.foreground = .index(value - 30)
            case 39:
                style.foreground = nil
            case 40...47:
                style.background = .index(value - 40)
            case 49:
                style.background = nil
            case 90...97:
                style.foreground = .index(value - 90 + 8)
            case 100...107:
                style.background = .index(value - 100 + 8)
            case 38, 48:
                let isForeground = value == 38
                if let mode = parameter(1), mode == 5, let n = parameter(2) {
                    let colour = TerminalColor.index(n)
                    if isForeground { style.foreground = colour } else { style.background = colour }
                    index += 2
                } else if let mode = parameter(1), mode == 2,
                          let r = parameter(2), let g = parameter(3), let b = parameter(4) {
                    let colour = TerminalColor.rgb(r, g, b)
                    if isForeground { style.foreground = colour } else { style.background = colour }
                    index += 4
                }
            default:
                break
            }
            index += 1
        }
    }

    // MARK: - Writing

    private func write(_ character: Character) {
        guard cellsAllowMore() else { return }
        let cell = TerminalCell(character: character, style: style)
        if cursor < current.cells.count {
            current.cells[cursor] = cell
        } else {
            current.cells.append(cell)
        }
        cursor += 1
    }

    private func cellsAllowMore() -> Bool {
        cursor < maxColumns || cursor < current.cells.count
    }

    private func tab() {
        let next = (cursor / 8 + 1) * 8
        while cursor < next { write(" ") }
    }

    private func backspace() {
        pendingCarriageReturn = false
        guard cursor > 0 else { return }
        cursor -= 1
        if cursor < current.cells.count {
            current.cells.remove(at: cursor)
        }
    }

    private func newline() {
        lines.append(current)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        current = TerminalLine()
        cursor = 0
    }
}
