import Foundation

/// A long-lived interactive shell into the embedded Linux, whose stdin the host
/// writes to and whose output the host reads as the guest produces it.
///
/// The engine's command primitive runs one command to completion and returns its
/// output, so it cannot host a shell you type into. This is the shape that can:
/// the guest runs a shell reading from a file the host appends to, and writing to
/// a file the host tails, both in the shared folder.
///
/// What that buys over one `/bin/sh -c` per line:
///  - the shell is persistent, so `cd`, variables, functions and shell options
///    survive between lines — no replaying `cd` on every command;
///  - the program can *read stdin*: `read`, `cat`, `sort`, or anything with a
///    prompt gets the bytes you type at the moment it asks for them;
///  - output appears as it is written, including partial lines and prompts that
///    do not end in a newline, which is what makes a password prompt usable.
///
/// What it does not buy: signals and job control. The engine has no way to
/// deliver a signal to a running child, so an interrupt detaches the screen
/// rather than stopping the guest, and the session says so instead of pretending.
@MainActor
protocol InteractiveShellSession: AnyObject {
    /// Guest path of the regular input file the host appends keystrokes to; the
    /// guest's `tail -f` turns it into the shell's stdin stream.
    var guestInput: String { get }
    /// Guest path of the file the shell's output is written to.
    var guestOutput: String { get }
    /// Guest pid of the shell, for logging and signalling.
    var pid: Int32 { get }
    /// False once the session has stopped; `send` reports failure rather than
    /// appearing to accept input nobody will read.
    var isRunning: Bool { get }

    /// Hand the session the guest process it is driving, once that process has
    /// been started. Until this is called the session is not usable. `onExit`
    /// fires if the shell ends on its own, so the UI can stop pretending a live
    /// prompt is there.
    func attach(process: any DetachedProcess, onExit: @escaping @MainActor () -> Void)

    /// Mark the session dead after the guest shell exits on its own.
    func markStopped()

    /// Send text to the shell's stdin. Returns false when the session is gone or
    /// the write failed, so a caller can say so instead of silently dropping it.
    @discardableResult
    func send(_ text: String) -> Bool

    /// Interrupt whatever the shell is running, with a real `SIGINT`.
    ///
    /// Not a Ctrl-C *byte*: that only becomes a signal when the program's stdin is
    /// a tty, and this transport is a pipe. The signal is delivered directly.
    func interruptForeground() async

    /// Send a single control byte — `0x04` for Ctrl-D (EOF), or any character the
    /// key bar cannot produce.
    @discardableResult
    func sendControl(_ scalar: UInt8) -> Bool

    /// Stop the guest shell and tailing, and mark the session finished.
    func stop()
}
