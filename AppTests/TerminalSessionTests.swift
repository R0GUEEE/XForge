import XCTest
@testable import XForge

/// The terminal is a shell you type into, not a command bar: what is typed goes
/// to a persistent shell's stdin, and what the shell prints is the screen.
///
/// These tests pin the parts that are easy to get subtly wrong — that a typed
/// line is delivered verbatim to the shell's standard input, that a program
/// reading stdin can therefore be answered, and that an interrupt is a real
/// signal rather than a character that only a tty would interpret.
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
        try XCTUnwrap(vm.startedShells.first, "the terminal should have started a shell")
    }

    func testBootingStartsAShellOnce() async throws {
        let (session, vm) = await makeSession()
        await session.boot()

        XCTAssertEqual(vm.startedShells.count, 1, "booting twice should reuse the shell")
        XCTAssertTrue(session.isBooted)
        XCTAssertTrue(try shell(of: vm).isRunning)
    }

    func testTypedLineGoesToTheShellsStandardInput() async throws {
        let (session, vm) = await makeSession()
        session.input = "echo hello"
        session.submit()

        // The line is delivered with a newline, which is what makes the shell
        // treat it as a complete command rather than a fragment.
        XCTAssertEqual(try shell(of: vm).received, ["echo hello\n"])
        XCTAssertEqual(session.input, "", "the field is cleared once the line is sent")
    }

    func testTheLineIsNotWrappedInAShellInvocation() async throws {
        // The old design composed `sh -c <command>` per line. Nothing is wrapped
        // now: the shell receives exactly what was typed, which is what lets
        // shell state (cd, variables) persist and lets a program read stdin.
        let (session, vm) = await makeSession()
        session.input = "cd /tmp && pwd"
        session.submit()

        let sent = try XCTUnwrap(try shell(of: vm).received.first)
        XCTAssertEqual(sent, "cd /tmp && pwd\n")
        XCTAssertFalse(sent.contains("/bin/sh"), "the host must not wrap the line in a shell call")
        XCTAssertFalse(sent.contains("__XFORGE_PWD__"),
                       "the host no longer needs to ask the shell where it is")
    }

    func testMultipleLinesAccumulateInOneShell() async throws {
        // The point of a persistent shell: each line joins the same session, so
        // the second command could depend on the first.
        let (session, vm) = await makeSession()
        for line in ["cd /etc", "cat hostname"] {
            session.input = line
            session.submit()
        }

        XCTAssertEqual(try shell(of: vm).received, ["cd /etc\n", "cat hostname\n"])
    }

    func testOutputFromTheShellReachesTheScreen() async throws {
        let (session, vm) = await makeSession()
        let shell = try shell(of: vm)

        // The guest writes from a background queue, and TerminalSession hops that
        // onto the main actor before touching the screen — so the assertion has to
        // let that hop run. That asynchrony is deliberate: the tailer must never
        // block on the UI.
        shell.emit("total 8\ndrwxr-xr-x\n")
        try await settle()
        XCTAssertTrue(session.buffer.plainText.contains("total 8"))

        let before = session.revision
        shell.emit("more\n")
        try await settle()
        XCTAssertGreaterThan(session.revision, before, "the view must be told to redraw")
    }

    /// Let queued main-actor hops from the guest run.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    func testInterruptIsASignalNotAControlCharacter() async throws {
        let (session, vm) = await makeSession()
        session.input = "sleep 100"
        session.submit()
        let shell = try shell(of: vm)
        let before = shell.received.count

        session.interrupt()
        // The signal is delivered asynchronously; give it a turn to land.
        try await settle()

        XCTAssertEqual(shell.interrupts, 1, "interrupt should signal the foreground program")
        XCTAssertEqual(shell.received.count, before,
                       "no byte should be written: 0x03 is only a signal on a tty")
    }

    func testCommandsFromOtherScreensJoinTheSameShell() async throws {
        let (session, vm) = await makeSession()
        session.enqueue("apk add --no-cache git", label: "Toolchain")
        try await settle()

        XCTAssertEqual(try shell(of: vm).received, ["apk add --no-cache git\n"])
        XCTAssertEqual(try shell(of: vm).pid, 4242, "it runs in the terminal's own shell")
    }

    func testShellExitIsReportedInsteadOfSwallowingInput() async throws {
        let (session, vm) = await makeSession()
        let shell = try shell(of: vm)
        shell.simulateExit()
        try await settle()

        XCTAssertFalse(session.running)
        XCTAssertTrue(session.buffer.plainText.contains("the shell exited"),
                      "the screen should say the shell is gone")
    }

    func testSendingWithNoShellReportsRatherThanDroppingTheLine() async throws {
        let (session, _) = await makeSession()
        session.shutdown()
        session.enqueue("echo lost")
        try await settle()

        XCTAssertTrue(session.buffer.plainText.contains("the shell is not running"),
                      "a queued line that cannot run must be visible")
    }
}
