import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The Terminal tab: a shell into the embedded Alpine Linux.
///
/// The screen *is* the terminal. The shell prints its own prompt, echoes what it
/// reads, and prints its own results, so there is no host-side prompt to draw and
/// no command bar to type into — the field at the bottom is the keyboard's target
/// and its contents are handed to the shell's stdin on return.
struct TerminalView: View {
    @EnvironmentObject private var session: TerminalSession

    @State private var fontSize: Double = 12
    @State private var showEngineLog = false
    @State private var importingXIP = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            canvas
            if !session.pending.isEmpty || session.activeLabel != nil {
                activityStrip
            }
            inputRow
            TerminalKeyBar(session: session,
                           onFiles: { session.enqueue("ls -la") },
                           onComponents: { component in install(component) },
                           onHideKeyboard: { inputFocused = false })
        }
        .background(Color.black)
        .navigationTitle("Alpine Linux")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task {
            await session.boot()
            inputFocused = true
        }
        .fileImporter(
            isPresented: $importingXIP,
            allowedContentTypes: [UTType(filenameExtension: "xip") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            stageXIP(url)
        }
        .sheet(isPresented: $showEngineLog) {
            NavigationStack { EngineLogView() }
        }
    }

    // MARK: - Screen

    private var canvas: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(session.buffer.lines.enumerated()), id: \.offset) { _, line in
                        TerminalLineView(line: line, fontSize: fontSize)
                    }
                    // The line the shell is part-way through writing. It is the
                    // shell's own output — a prompt, a partial result, or the echo
                    // of what was typed — so it is drawn exactly like any other
                    // line and only kept separate so it can grow in place.
                    if !session.buffer.current.isEmpty {
                        TerminalLineView(line: session.buffer.current, fontSize: fontSize)
                            .id(Self.bottomID)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.black)
            .onChange(of: session.revision) { _ in
                withAnimation(.none) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: session.buffer.lines.count) { _ in
                withAnimation(.none) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { inputFocused = true }
    }

    private static let bottomID = "org.xforge.terminal.bottom"

    // MARK: - Status strip

    /// Shown while something is outstanding. There is no "running" indicator for
    /// an ordinary command any more: the shell is always there, so the absence of
    /// a prompt is the indication that a program is still working.
    private var activityStrip: some View {
        HStack(spacing: 8) {
            if !session.pending.isEmpty {
                ProgressView().controlSize(.mini).tint(.white)
                Text("\(session.pending.count) command(s) queued")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
            } else if let label = session.activeLabel {
                Text("requested by \(label)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(white: 0.13))
    }

    // MARK: - Input

    /// A single line that stands in for the keyboard: what is typed here is
    /// written to the shell's stdin on return. It deliberately draws no prompt of
    /// its own — the prompt on screen is the shell's.
    private var inputRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: fontSize - 1, weight: .bold))
                .foregroundStyle(Color.green.opacity(0.7))

            TextField(session.booting ? "starting the embedded Linux…" : "type a command",
                      text: $session.input,
                      axis: .vertical)
                .lineLimit(1...6)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(Color(white: 0.92))
                .tint(.green)
                .focused($inputFocused)
                .disabled(session.booting)
                .submitLabel(.go)
                .onSubmit {
                    session.submit()
                    // Keep the keyboard up: this is a terminal, and the next
                    // command is usually typed immediately.
                    inputFocused = true
                }

            if session.booting {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(white: 0.10))
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text("Alpine Linux").font(.footnote.bold())
                Text(session.cwd).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Section("Components") {
                    ForEach(SystemComponents.Component.allCases) { component in
                        Button {
                            install(component)
                        } label: {
                            Label("Install the \(component.title)", systemImage: icon(for: component))
                        }
                    }
                    Button {
                        importingXIP = true
                    } label: {
                        Label("Install the Darwin SDK from an Xcode.xip…",
                              systemImage: "doc.badge.plus")
                    }
                }

                Section("Session") {
                    Button { UIPasteboard.general.string = session.buffer.plainText } label: {
                        Label("Copy transcript", systemImage: "doc.on.doc")
                    }
                    Button { session.clear() } label: {
                        Label("Clear", systemImage: "eraser")
                    }
                    Button { session.recall(offset: -1) } label: {
                        Label("Previous command", systemImage: "chevron.up")
                    }
                    .disabled(session.history.isEmpty)
                }

                Section("Font size") {
                    Button { fontSize = max(9, fontSize - 1) } label: {
                        Label("Smaller", systemImage: "textformat.size.smaller")
                    }
                    Button { fontSize = min(20, fontSize + 1) } label: {
                        Label("Larger", systemImage: "textformat.size.larger")
                    }
                }

                Section {
                    Button { showEngineLog = true } label: {
                        Label("Engine log", systemImage: "doc.text.magnifyingglass")
                    }
                }
            } label: {
                Label("Terminal options", systemImage: "ellipsis.circle")
            }
        }
    }

    private func icon(for component: SystemComponents.Component) -> String {
        switch component {
        case .glibc: return "shippingbox"
        case .xtool: return "hammer"
        case .swift: return "swift"
        case .darwinSDK: return "externaldrive.connected.to.line.below"
        }
    }

    // MARK: - Actions

    /// Queue a component install in the terminal so its output is visible here.
    private func install(_ component: SystemComponents.Component) {
        switch component {
        case .glibc:
            session.enqueue(SystemComponents.scriptCommand(.glibc), label: "Components")
        case .xtool:
            Task { await prepareInstallerScript(); session.enqueue(SystemComponents.xtoolInstallCommand, label: "Components") }
        case .swift:
            Task { await prepareInstallerScript(); session.enqueue(SystemComponents.swiftInstallCommand, label: "Components") }
        case .darwinSDK:
            importingXIP = true
        }
    }

    private func prepareInstallerScript() async {
        do {
            let vm = XForgeEnvironment.makeVM()
            try await vm.boot()
            try await SystemComponents.ensureInstallerScript(in: vm)
        } catch {
            session.enqueue("echo \(GuestShell.quote("install-toolchain.sh: \(error.localizedDescription)"))",
                            label: "Components")
        }
    }

    /// Copy the chosen `.xip` into the guest's own filesystem, then hand xtool
    /// the install command.
    private func stageXIP(_ url: URL) {
        session.enqueue("echo \(GuestShell.quote("staging \(url.lastPathComponent) into the guest…"))",
                        label: "Components")
        Task {
            do {
                let vm = XForgeEnvironment.makeVM()
                await vm.prepareRootfs()
                try await vm.boot()
                let guestPath = try await SystemComponents.stageXIP(url, in: vm) { line in
                    XForgeLog.note("components: \(line)")
                }
                session.enqueue(SystemComponents.darwinSDKInstallCommand(guestXIPPath: guestPath),
                                label: "Components")
            } catch {
                session.enqueue("echo \(GuestShell.quote("could not stage the xip: \(error.localizedDescription)"))",
                                label: "Components")
            }
        }
    }
}

/// One line of the screen.
private struct TerminalLineView: View {
    let line: TerminalLine
    let fontSize: Double

    var body: some View {
        Text(line.attributedString(fontSize: fontSize))
            .font(.system(size: fontSize, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}

/// the iSH terminal's extra-keys bar: the characters a phone keyboard cannot produce,
/// between the terminal and the keyboard.
private struct TerminalKeyBar: View {
    @ObservedObject var session: TerminalSession
    var onFiles: () -> Void
    var onComponents: (SystemComponents.Component) -> Void
    var onHideKeyboard: () -> Void

    private static let punctuation = ["-", ".", "/", ":", "!", "|"]

    /// Key metrics, defined once. The keys are deliberately small — they sit
    /// under the terminal and exist to supply characters a phone keyboard cannot
    /// produce, not to be a primary control surface.
    private static let keyWidth: CGFloat = 15
    private static let keyHeight: CGFloat = 14
    private static let keySpacing: CGFloat = 3
    /// The glyph is inset from the key so a symbol never touches the border, and
    /// shrinks with it: at the old 30x28 the symbols were drawn at the body font
    /// size, which would overflow a 15x14 key.
    private static var glyphSize: CGFloat { 9 }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Self.keySpacing) {
                // Ctrl-C is delivered as a byte on stdin, which is the one
                // signal path the transport supports — and the foreground
                // program reading that stdin does see it, exactly as it would
                // from a real terminal. Ctrl-D closes the shell's input.
                symbolKey("Interrupt (Ctrl-C)", "control") { session.interrupt() }
                symbolKey("Escape", "escape") { session.insert("\u{1b}") }
                symbolKey("Tab", "arrow.right.to.line.alt") { session.insert("\t") }
                textKey("↑") { session.recall(offset: -1) }
                textKey("↓") { session.recall(offset: 1) }

                divider

                ForEach(Self.punctuation, id: \.self) { character in
                    textKey(character) { session.insert(character) }
                }

                divider

                componentsMenu
                symbolKey("Files", "folder") { onFiles() }
                symbolKey("Paste", "doc.on.clipboard") { session.pasteFromClipboard() }
                symbolKey("Hide Keyboard", "keyboard.chevron.compact.down") { onHideKeyboard() }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .background(Color(white: 0.16))
        .accessibilityLabel("Terminal keyboard")
    }

    private var divider: some View {
        Divider().frame(height: Self.keyHeight + 2)
    }

    private func textKey(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: Self.glyphSize + 1, design: .monospaced))
                .frame(width: Self.keyWidth, height: Self.keyHeight)
        }
        .buttonStyle(.bordered)
        .tint(.white)
    }

    /// The gear/wrench key: the system components, installed by command.
    private var componentsMenu: some View {
        Menu {
            ForEach(SystemComponents.Component.allCases) { component in
                Button(component.title) { onComponents(component) }
            }
        } label: {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: Self.glyphSize))
                .frame(width: Self.keyWidth, height: Self.keyHeight)
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .accessibilityLabel("Components")
    }

    private func symbolKey(_ label: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Self.glyphSize))
                .frame(width: Self.keyWidth, height: Self.keyHeight)
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .accessibilityLabel(label)
    }
}

/// Tab wrapper, so the root view can hand the terminal its session.
struct TerminalTab: View {
    var body: some View {
        NavigationStack {
            TerminalView()
        }
    }
}
