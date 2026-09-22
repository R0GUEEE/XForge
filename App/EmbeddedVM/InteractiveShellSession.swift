import Foundation

/// A live shell in the embedded Linux: what the terminal types into.
///
/// The shell runs on the guest's **console**, which the host implements as a tty
/// (`GuestConsole`). That is the whole design, and it is what makes the terminal a
/// terminal rather than a pipe:
///  - the host writes keystrokes into the guest's tty, so the guest kernel's line
///    discipline supplies echo, backspace, line editing, `Ctrl-D` and the rest;
///  - `Ctrl-C` is a *byte* again, turned into `SIGINT` for the foreground program
///    by the tty — so an interrupt reaches whatever is running, including
///    `Ctrl-Z`'s job control;
///  - output appears as the guest writes it, including prompts that do not end in
///    a newline, which is what makes a password prompt or a progress bar usable.
///
/// The guest's `/sbin/init` owns that console and respawns `/bin/login -f root` on
/// it, so the shell is login's child: logging out gives a fresh login rather than
/// a dead screen.
@MainActor
protocol InteractiveShellSession: AnyObject {
    /// Guest pid the session speaks for. For a console login this is init, which
    /// owns the console; the shell itself is init's child and may be replaced.
    var pid: Int32 { get }
    /// False once the session has stopped; `send` reports failure rather than
    /// appearing to accept input nobody will read.
    var isRunning: Bool { get }

    /// Send text to the console. Returns false when the session is gone or there
    /// is no console to write to, so a caller can say so instead of silently
    /// dropping it.
    @discardableResult
    func send(_ text: String) -> Bool

    /// Send a single control byte — `0x03` for Ctrl-C, `0x04` for Ctrl-D — or any
    /// character the key bar cannot produce.
    @discardableResult
    func sendControl(_ scalar: UInt8) -> Bool

    /// Interrupt whatever is running in the foreground, with a real `SIGINT`.
    ///
    /// This is the Ctrl-C *character* written to the console: the guest's tty
    /// turns it into the signal for the foreground process group, which is exactly
    /// what a terminal is supposed to do.
    func interruptForeground() async

    /// Tell the guest how big the screen is, so its programs wrap and lay out
    /// correctly.
    func resize(cols: Int, rows: Int)

    /// Stop the session and its console reader.
    func stop()
}
