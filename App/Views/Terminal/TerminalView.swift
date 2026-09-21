import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The Terminal tab: a shell into the embedded Alpine Linux.
///
/// The layout follows iSH-AOK's terminal — the screen is the terminal, with a
/// key bar of the characters a phone keyboard does not have (Tab, Ctrl, Esc,
/// arrows, `- . / : ! |`, paste) sitting between it and the keyboard.
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
                           size: fontSize,
                           onFiles: { session.enqueue("ls -la") },
                           onComponents: { component in install(component) },
                           onHideKeyboard: { inputFocused = false })
        }
        .background(Color.black)
        .navigationTitle("Alpine Linux")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task { await session.boot() }
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
                    TerminalLineView(line: promptLine, fontSize: fontSize)
                        .id(Self.bottomID)
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
    }

    private static let bottomID = "org.xforge.terminal.bottom"

    /// The line being written: the guest's partial output, or the host's prompt
    /// with a cursor when the guest is not saying anything.
    private var promptLine: TerminalLine {
        var line = session.buffer.current
        if !session.running && !session.booting {
            line.cells.append(TerminalCell(character: "▊",
                                           style: TerminalStyle(foreground: .index(10))))
        }
        return line
    }

    // MARK: - Status strip

    private var activityStrip: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini).tint(.white)
            Text(session.activeLabel.map { "\($0) — running" }
                 ?? "\(session.pending.count) command(s) queued")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            if session.running {
                Button("Stop") { session.interrupt() }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(white: 0.13))
    }

    // MARK: - Input

    private var inputRow: some View {
        HStack(spacing: 8) {
            Text(session.prompt)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(Color.green)
                .lineLimit(1)

            TextField(session.booting ? "starting the embedded Linux…" : "command",
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
                .onSubmit { session.submit() }

            if session.booting {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    session.submit()
                } label: {
                    Label("Run", systemImage: "return")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 18))
                }
                .disabled(session.pending.isEmpty && session.input.isEmpty && !session.running)
                .tint(.green)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
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
        session.enqueue(TerminalSession.TerminalCommand(
            text: "echo \(GuestShell.quote("staging \(url.lastPathComponent) into the guest…"))",
            label: "Components"))
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

/// iSH-AOK's extra-keys bar: the characters a phone keyboard cannot produce,
/// between the terminal and the keyboard.
private struct TerminalKeyBar: View {
    @ObservedObject var session: TerminalSession
    let size: Double
    var onFiles: () -> Void
    var onComponents: (SystemComponents.Component) -> Void
    var onHideKeyboard: () -> Void

    private static let punctuation = ["-", ".", "/", ":", "!", "|"]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                symbolKey("Tab", "arrow.right.to.line.alt") { session.insert("\t") }
                symbolKey("Control", "control") { session.interrupt() }
                symbolKey("Escape", "escape") { session.insert("\u{1b}") }
                textKey("↑") { session.recall(offset: -1) }
                textKey("↓") { session.recall(offset: 1) }

                Divider().frame(height: 20)

                ForEach(Self.punctuation, id: \.self) { character in
                    textKey(character) { session.insert(character) }
                }

                Divider().frame(height: 20)

                componentsMenu
                symbolKey("Files", "folder") { onFiles() }
                symbolKey("Paste", "doc.on.clipboard") { session.pasteFromClipboard() }
                symbolKey("Hide Keyboard", "keyboard.chevron.compact.down") { onHideKeyboard() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Color(white: 0.16))
        .accessibilityLabel("Terminal keyboard")
    }

    private func textKey(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: size + 1, design: .monospaced))
                .frame(minWidth: 30, minHeight: 28)
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
                .font(.system(size: size + 1))
                .frame(minWidth: 30, minHeight: 28)
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .accessibilityLabel("Components")
    }

    private func symbolKey(_ label: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size + 1))
                .frame(minWidth: 30, minHeight: 28)
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
