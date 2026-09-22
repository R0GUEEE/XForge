import Foundation

/// The terminal's shell, as it actually is: the guest's console.
///
/// There is nothing to attach and nothing to wait for — the console is up as soon
/// as the guest's init has opened it, and it stays up. Typing goes into the tty;
/// the guest's own line discipline does the rest. See `InteractiveShellSession`.
@MainActor
final class ConsoleShellSession: InteractiveShellSession {
    private let console: any GuestConsole

    /// init owns the console, and it respawns the session the user types into, so
    /// init is the process this session speaks for.
    let pid: Int32 = 1
    private(set) var isRunning = true

    /// Ctrl-C, the byte the guest's tty turns into SIGINT for the foreground
    /// group.
    private static let interruptByte: UInt8 = 0x03

    init(console: any GuestConsole) {
        self.console = console
    }

    @discardableResult
    func send(_ text: String) -> Bool {
        guard isRunning else { return false }
        return console.write(text)
    }

    @discardableResult
    func sendControl(_ scalar: UInt8) -> Bool {
        guard isRunning else { return false }
        return console.write(String(UnicodeScalar(scalar)))
    }

    func interruptForeground() async {
        _ = sendControl(Self.interruptByte)
    }

    func resize(cols: Int, rows: Int) {
        guard isRunning else { return }
        console.resize(cols: cols, rows: rows)
    }

    func stop() {
        isRunning = false
        console.stop()
    }
}
