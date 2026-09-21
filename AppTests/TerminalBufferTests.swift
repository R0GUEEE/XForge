import XCTest
@testable import XForge

/// The terminal's screen model is the part of the Terminal tab that cannot be
/// checked by looking at the app: the guest is a real Linux system, so its output
/// arrives as carriage returns, backspaces and SGR colour that have to be turned
/// into a screen. These tests feed it what the guest actually sends.
@MainActor
final class TerminalBufferTests: XCTestCase {

    func testPlainOutputIsSplitIntoScreenLines() {
        let buffer = TerminalBuffer()
        buffer.feed("hello\nworld")

        XCTAssertEqual(buffer.lines.map(\.text), ["hello"])
        XCTAssertEqual(buffer.current.text, "world")
    }

    func testCarriageReturnOverwritesTheCurrentLine() {
        let buffer = TerminalBuffer()
        buffer.feed("100%\r50%")

        // What a terminal shows: the new text written over the old one, so the
        // column the old text occupied but the new one does not keeps its
        // character.
        XCTAssertEqual(buffer.current.text, "50%%")
        XCTAssertTrue(buffer.lines.isEmpty)
    }

    func testCarriageReturnNewlineIsOneNewline() {
        let buffer = TerminalBuffer()
        buffer.feed("abc\r\n")

        XCTAssertEqual(buffer.lines.map(\.text), ["abc"])
        XCTAssertTrue(buffer.current.isEmpty)
    }

    func testBackspaceErasesThePreviousCharacter() {
        let buffer = TerminalBuffer()
        buffer.feed("ab\u{08}c")

        XCTAssertEqual(buffer.current.text, "ac")
    }

    func testTabAdvancesToTheNextTabStop() {
        let buffer = TerminalBuffer()
        buffer.feed("a\tb")

        XCTAssertEqual(buffer.current.text, "a       b")
    }

    func testColourIsKeptAsStyleAndNotAsText() {
        let buffer = TerminalBuffer()
        buffer.feed("\u{1b}[1;31mred\u{1b}[0m plain")

        XCTAssertEqual(buffer.current.text, "red plain")
        XCTAssertEqual(buffer.current.cells.first?.style.foreground, .index(1))
        XCTAssertEqual(buffer.current.cells.first?.style.bold, true)
        // The reset returns the rest of the line to the default style.
        XCTAssertEqual(buffer.current.cells.last?.style, .plain)
    }

    func testTrueColourAndExtendedPalette() {
        let buffer = TerminalBuffer()
        buffer.feed("\u{1b}[38;2;10;20;30mtruecolour")
        XCTAssertEqual(buffer.current.cells.first?.style.foreground, .rgb(10, 20, 30))

        buffer.feed("\u{1b}[0m\u{1b}[38;5;208mindexed")
        XCTAssertEqual(buffer.current.cells.last?.style.foreground, .index(208))
    }

    func testClearScreenRemovesTheScrollback() {
        let buffer = TerminalBuffer()
        buffer.feed("one\ntwo\n")
        buffer.feed("\u{1b}[2J")

        XCTAssertTrue(buffer.lines.isEmpty)
        XCTAssertTrue(buffer.current.isEmpty)
        XCTAssertTrue(buffer.isAtStart)
    }

    func testEraseInLineLeavesTheScrollbackAlone() {
        let buffer = TerminalBuffer()
        buffer.feed("kept\npartly")
        buffer.feed("\u{1b}[K")

        XCTAssertEqual(buffer.lines.map(\.text), ["kept"])
        // The cursor sits at the end of the text, so there is nothing after it to
        // erase — the line is unchanged and the scrollback is untouched.
        XCTAssertEqual(buffer.current.text, "partly")
    }

    func testAnEscapeSequenceSplitAcrossChunksStillApplies() {
        // Output arrives in whatever size the transport hands over; a sequence
        // must survive being cut in half.
        let buffer = TerminalBuffer()
        buffer.feed("\u{1b}[3")
        buffer.feed("1mgreen")

        XCTAssertEqual(buffer.current.text, "green")
        XCTAssertEqual(buffer.current.cells.first?.style.foreground, .index(1))
    }

    func testUnsupportedSequencesAreSwallowedWithoutLosingText() {
        let buffer = TerminalBuffer()
        buffer.feed("\u{1b}[1;1Hmove\u{1b}]0;window title\u{07}after")

        XCTAssertEqual(buffer.current.text, "moveafter")
    }

    func testScrollbackIsCapped() {
        let buffer = TerminalBuffer()
        buffer.maxLines = 10
        for index in 0..<50 { buffer.feed("line \(index)\n") }

        XCTAssertEqual(buffer.lines.count, 10)
        XCTAssertEqual(buffer.lines.last?.text, "line 49")
    }

    func testHostLinesAreStyledWithoutLeakingIntoGuestOutput() {
        let buffer = TerminalBuffer()
        buffer.appendLine("$ ls", style: TerminalStyle(foreground: .index(10)))
        buffer.feed("guest output")

        XCTAssertEqual(buffer.lines.first?.text, "$ ls")
        XCTAssertEqual(buffer.current.cells.first?.style, .plain)
    }
}
