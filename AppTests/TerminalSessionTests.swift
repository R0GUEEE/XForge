import XCTest
@testable import XForge

/// The terminal is the guest's console: what is typed goes into the guest's tty,
/// the guest's own line discipline and shell do the editing and echoing, and what
/// the tty produces is the screen.
///
/// These tests pin the parts that are easy to get subtly wrong — that a typed
/// line reaches the console verbatim (no host-side shell wrapping, no host-side
/// echoing), that an interrupt is the Ctrl-C *byte* for the tty to turn into a
/// signal, and that the guest is told how big the screen is.
@MainActor
final class TerminalSessionTests: XCTestCase {

    /// A session wired to a stub guest, with its transcript kept out of the way.
    private func makeSession() async -> (TerminalSession, StubLinuxVM) {
        let vm = StubLinuxVM()
        let session = TerminalSession(makeVM: { vm })
        await session.boot()
        return (session, vm)
    }

    private func shell(of vm: StubLinuxVM) throws -> StubShellSession {
        try XCTUnwrap(vm.startedShells.first, "the terminal should have attached to a console")
    }

    func testBootingAttachesToTheConsoleOnce() async throws {
        let (session, vm) = await makeSession()
        await session.boot()

        XCTAssertEqual(vm.startedShells.count, 1, "booting twice should reuse the session")
        XCTAssertTrue(session.isBooted)
        XCTAssertTrue(try shell(of: vm).isRunning)
    }

    func testTypedLineGoesToTheConsoleVerbatim() async throws {
        let (session, vm) = await makeSession()
        session.sendRaw("echo hello\n")

        // Exactly what was typed, newline included: the tty and the shell are what
        // interpret it.
        XCTAssertEqual(try shell(of: vm).received, ["echo hello\n"])
    }

    func testTheLineIsNotWrappedInAShellInvocation() async throws {
        // The old design composed `sh -c <command>` per line. Nothing is wrapped
        // now: the console receives exactly what was typed, which is what lets
        // shell state (cd, variables) persist and lets a program read stdin.
        let (session, vm) = await makeSession()
        session.sendRaw("cd /tmp && pwd\n")

        let sent = try XCTUnwrap(try shell(of: vm).received.first)
        XCTAssertEqual(sent, "cd /tmp && pwd\n")
        XCTAssertFalse(sent.contains("/bin/sh"), "the host must not wrap the line in a shell call")
        XCTAssertFalse(sent.contains("__XFORGE_PWD__"),
                       "the host no longer needs to ask the shell where it is")
    }

    func testKeystrokesReachTheConsoleOneChunkAtATime() async throws {
        // A terminal sends what was typed, not whole lines: the guest has to see
        // each keystroke so its line discipline can echo it, and so `read` in a
        // running program can consume it character by character.
        let (session, vm) = await makeSession()
        for text in ["l", "s", "\n"] {
            session.sendRaw(text)
        }

        XCTAssertEqual(try shell(of: vm).received, ["l", "s", "\n"])
    }

    func testMultipleLinesAccumulateInOneSession() async throws {
        // The console is persistent: each line joins the same login session, so the
        // second command could depend on the first.
        let (session, vm) = await makeSession()
        for line in ["cd /etc", "cat hostname"] {
            session.sendRaw(line + "\n")
        }

        XCTAssertEqual(try shell(of: vm).received, ["cd /etc\n", "cat hostname\n"])
    }

    func testOutputFromTheConsoleReachesTheScreen() async throws {
        let (session, vm) = await makeSession()
        let shell = try shell(of: vm)

        // The guest writes from its own thread, and TerminalSession hops that onto
        // the main actor before touching the screen — so the assertion has to let
        // that hop run. That asynchrony is deliberate: the reader must never block
        // on the UI.
        shell.emit("total 8\ndrwxr-xr-x\n")
        try await settle()
        XCTAssertTrue(session.buffer.plainText.contains("total 8"))

        let before = session.revision
        shell.emit("more\n")
        try await settle()
        XCTAssertGreaterThan(session.revision, before, "the view must be told to redraw")
    }

    func testOutputThatDoesNotEndInANewlineIsShown() async throws {
        // A prompt, or a program waiting for input, writes without a trailing
        // newline. Dropping that would leave the screen looking dead while the
        // guest waits for an answer.
        let (session, vm) = await makeSession()
        try shell(of: vm).emit("Password: ")
        try await settle()

        XCTAssertTrue(session.buffer.plainText.contains("Password: "))
    }

    /// Let queued main-actor hops from the guest run.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    func testInterruptIsTheCtrlCByte() async throws {
        // Ctrl-C is a byte again, because the console is a real tty: the guest's
        // line discipline is what turns 0x03 into SIGINT for the foreground
        // process group.
        let (session, vm) = await makeSession()
        session.sendRaw("sleep 100\n")
        let shell = try shell(of: vm)
        let before = shell.received.count

        session.interrupt()
        try await settle()

        XCTAssertEqual(shell.interrupts, 1)
        XCTAssertEqual(shell.received.count, before + 1, "the interrupt is one byte")
        XCTAssertEqual(shell.received.last, "\u{3}", "and it is Ctrl-C")
    }

    func testCommandsFromOtherScreensJoinTheSameConsole() async throws {
        let (session, vm) = await makeSession()
        session.enqueue("apk add --no-cache git", label: "Toolchain")
        try await settle()

        XCTAssertEqual(try shell(of: vm).received, ["apk add --no-cache git\n"])
        XCTAssertEqual(try shell(of: vm).pid, 4242, "it runs on the console the terminal is on")
    }

    func testTheGuestIsToldHowBigTheScreenIs() async throws {
        // A guest that believes its terminal is 0×0 wraps everything to one column,
        // so the size has to reach it — and only when it actually changes, since
        // each report raises SIGWINCH in the guest.
        let (session, vm) = await makeSession()
        session.consoleResized(cols: 80, rows: 24)
        session.consoleResized(cols: 80, rows: 24)
        session.consoleResized(cols: 120, rows: 40)

        XCTAssertEqual(try shell(of: vm).sizes.map { "\($0.cols)x\($0.rows)" },
                       ["80x24", "120x40"])
    }

    func testSendingWithNoConsoleReportsRatherThanDroppingTheLine() async throws {
        let (session, _) = await makeSession()
        session.shutdown()
        session.enqueue("echo lost")
        try await settle()

        XCTAssertTrue(session.buffer.plainText.contains("the shell is not running"),
                      "a queued line that cannot run must be visible")
    }
}
