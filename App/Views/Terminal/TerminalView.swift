import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The Terminal tab: the guest's console.
///
/// The screen *is* the terminal. Alpine boots `/sbin/init` as pid 1, which starts
/// root's login shell on the console, and the console is this view: what you type goes
/// into the guest's tty, and what the tty produces is drawn here. The shell prints
/// its own prompt and echoes its own input, so there is nothing host-side to draw
/// or interpret.
struct TerminalView: View {
    @EnvironmentObject private var session: TerminalSession

    @State private var fontSize: Double = 12
    @State private var showGuestFiles = false
    @State private var showEngineLog = false
    @State private var importingXIP = false
    /// Which keys the extra-keys bar shows. Shared with the configuration sheet.
    @StateObject private var keyConfiguration = TerminalKeyConfiguration()
    @State private var showKeyConfiguration = false

    var body: some View {
        VStack(spacing: 0) {
            canvas
            if !session.pending.isEmpty || session.activeLabel != nil {
                activityStrip
            }
            TerminalKeyBar(session: session,
                           configuration: keyConfiguration,
                           onFiles: { showGuestFiles = true },
                           onComponents: { component in install(component) },
                           onHideKeyboard: { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) },
                           onConfigure: { showKeyConfiguration = true })
        }
        .background(Color.black)
        .navigationTitle("Alpine Linux")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task {
            await session.boot()
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
        .sheet(isPresented: $showGuestFiles) {
            GuestFileBrowserView()
        }
        .sheet(isPresented: $showKeyConfiguration) {
            TerminalKeyConfigurationView()
                .environmentObject(keyConfiguration)
        }
    }

    // MARK: - Screen

    private var canvas: some View {
        InteractiveTerminalSurface(session: session, fontSize: fontSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
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
                    Button { session.sendRaw("\u{1b}[A") } label: {
                        Label("Previous command", systemImage: "chevron.up")
                    }
                }

                Section("Keys") {
                    Button { showKeyConfiguration = true } label: {
                        Label("Configure terminal keys…", systemImage: "slider.horizontal.3")
                    }
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

/// A native iOS terminal surface. The view itself becomes first responder, so
/// software/hardware keyboard events go directly to Alpine instead of through a
/// separate command field. Touch controls scrolling and selects/copies terminal
/// text; tapping the terminal summons the iOS keyboard.
private struct InteractiveTerminalSurface: UIViewRepresentable {
    @ObservedObject var session: TerminalSession
    let fontSize: Double

    func makeUIView(context: Context) -> TerminalTextView {
        let view = TerminalTextView()
        view.session = session
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.refresh(from: session)
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: TerminalTextView, context: Context) {
        view.session = session
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.refresh(from: session)
    }
}

private final class TerminalTextView: UITextView {
    weak var session: TerminalSession?
    private var lastRevision = -1

    override var canBecomeFirstResponder: Bool { true }
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        backgroundColor = .black
        textColor = UIColor(white: 0.92, alpha: 1)
        tintColor = .systemGreen
        isEditable = true
        isSelectable = true
        keyboardType = .asciiCapable
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        textContainerInset = UIEdgeInsets(top: 6, left: 8, bottom: 8, right: 8)
        // `self.` is required: inside this initializer the parameter named
        // `textContainer` shadows the property of the same name, and the
        // parameter is optional — `textContainer.lineFragmentPadding` reads as
        // an optional member access and does not compile.
        self.textContainer.lineFragmentPadding = 0
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(focusTerminal)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func focusTerminal() { becomeFirstResponder() }

    /// Report the terminal's size in characters to the guest.
    ///
    /// Without this the guest believes its terminal is 0×0 and every program that
    /// lays out by width breaks: `ls` prints one name per line, and anything
    /// full-screen draws in a corner. The cell size comes from the same
    /// monospaced font the text is drawn in.
    override func layoutSubviews() {
        super.layoutSubviews()
        reportSize()
    }

    private func reportSize() {
        guard let session, let font,
              bounds.width > 0, bounds.height > 0 else { return }
        let advance = ("W" as NSString).size(withAttributes: [.font: font]).width
        guard advance > 0 else { return }
        let usableWidth = bounds.width - textContainerInset.left - textContainerInset.right
        let usableHeight = bounds.height - textContainerInset.top - textContainerInset.bottom
        let cols = Int(usableWidth / advance)
        let rows = Int(usableHeight / font.lineHeight)
        guard cols > 0, rows > 0 else { return }
        session.consoleResized(cols: cols, rows: rows)
    }

    func refresh(from session: TerminalSession) {
        guard lastRevision != session.revision else { return }
        lastRevision = session.revision
        let wasNearBottom = contentOffset.y + bounds.height >= contentSize.height - 44
        let rendered = session.buffer.plainText
        if text != rendered { text = rendered }
        selectedRange = NSRange(location: (text as NSString).length, length: 0)
        if wasNearBottom || !isTracking {
            let end = NSRange(location: (text as NSString).length, length: 0)
            scrollRangeToVisible(end)
        }
    }

    // UIKeyInput is intentionally implemented even though the UITextView is not
    // editable: UIKit still presents the keyboard, while every keystroke is sent
    // to the guest shell instead of mutating host-side text.
    override var hasText: Bool { true }
    override func insertText(_ text: String) {
        session?.sendRaw(text)
    }
    override func deleteBackward() {
        session?.sendRaw("\u{7f}")
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(upArrow)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(downArrow)),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(leftArrow)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(rightArrow)),
            UIKeyCommand(input: "c", modifierFlags: .control, action: #selector(controlC)),
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(tabKey)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapeKey))
        ]
    }

    @objc private func upArrow() { session?.sendRaw("\u{1b}[A") }
    @objc private func downArrow() { session?.sendRaw("\u{1b}[B") }
    @objc private func leftArrow() { session?.sendRaw("\u{1b}[D") }
    @objc private func rightArrow() { session?.sendRaw("\u{1b}[C") }
    @objc private func controlC() { session?.interrupt() }
    @objc private func tabKey() { session?.sendRaw("\t") }
    @objc private func escapeKey() { session?.sendRaw("\u{1b}") }
}

/// the iSH terminal's extra-keys bar: the characters a phone keyboard cannot produce,
/// between the terminal and the keyboard.
private struct TerminalKeyBar: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var configuration: TerminalKeyConfiguration
    var onFiles: () -> Void
    var onComponents: (SystemComponents.Component) -> Void
    var onHideKeyboard: () -> Void
    var onConfigure: () -> Void

    /// Key metrics, defined once. The keys are deliberately small — they sit
    /// under the terminal and exist to supply characters a phone keyboard cannot
    /// produce, not to be a primary control surface.
    private static let keyWidth: CGFloat = 15
    private static let keyHeight: CGFloat = 14
    private static let keySpacing: CGFloat = 3
    /// The glyph is inset from the key so a symbol never touches the border.
    private static var glyphSize: CGFloat { 9 }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Self.keySpacing) {
                ForEach(configuration.visibleKeys) { key in
                    self.key(key)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .background(Color(white: 0.16))
        .accessibilityLabel("Terminal keyboard")
    }

    /// One key, rendered from its declaration rather than from a hard-coded row,
    /// so the configuration and the bar cannot disagree about what exists.
    @ViewBuilder
    private func key(_ key: TerminalKey) -> some View {
        switch key {
        case .components:
            componentsMenu
        default:
            Button {
                activate(key)
            } label: {
                if let symbol = key.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: Self.glyphSize))
                        .frame(width: Self.keyWidth, height: Self.keyHeight)
                } else {
                    Text(key.label)
                        .font(.system(size: Self.glyphSize + 1, design: .monospaced))
                        .frame(width: Self.keyWidth, height: Self.keyHeight)
                }
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .accessibilityLabel(key.title)
            .contextMenu {
                // Turning a key off from the key itself is the fastest way to
                // trim the bar, but the configuration sheet is where keys that
                // are already hidden can be brought back.
                if !key.isPinned {
                    Button("Hide “\(key.title)”", systemImage: "eye.slash") {
                        configuration.setVisible(false, for: key)
                    }
                }
                Button("Configure keys…", systemImage: "slider.horizontal.3") {
                    onConfigure()
                }
            }
        }
    }

    private func activate(_ key: TerminalKey) {
        switch key {
        case .interrupt: session.interrupt()
        // Everything else is a raw byte sequence for the console. The guest owns
        // the editing — its line discipline and the shell's own line editor — so
        // the key bar only has to produce the characters a phone keyboard cannot,
        // and the shell's history is reached with the arrow keys it understands.
        case .escape: session.sendRaw("\u{1b}")
        case .tab: session.sendRaw("\t")
        case .previous: session.sendRaw("\u{1b}[A")
        case .next: session.sendRaw("\u{1b}[B")
        case .dash: session.sendRaw("-")
        case .dot: session.sendRaw(".")
        case .slash: session.sendRaw("/")
        case .colon: session.sendRaw(":")
        case .bang: session.sendRaw("!")
        case .pipe: session.sendRaw("|")
        case .files: onFiles()
        case .paste: session.pasteFromClipboard()
        case .hideKeyboard: onHideKeyboard()
        case .components: break   // rendered as a menu, never reaches here
        }
    }

    /// The gear/wrench key: the system components, installed by command.
    private var componentsMenu: some View {
        Menu {
            ForEach(SystemComponents.Component.allCases) { component in
                Button(component.title) { onComponents(component) }
            }
            Divider()
            Button("Configure keys…", systemImage: "slider.horizontal.3") {
                onConfigure()
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
}

/// Chooses which keys the extra-keys bar shows.
///
/// Hide Keyboard is listed but not switchable, with the reason stated: without it
/// there is no way back to the screen once the keyboard covers it.
private struct TerminalKeyConfigurationView: View {
    @EnvironmentObject private var configuration: TerminalKeyConfiguration
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(configuration.order) { key in
                        row(for: key)
                    }
                    .onMove(perform: configuration.move)
                } header: {
                    Text("Command bar")
                } footer: {
                    Text("Drag to reorganize buttons. Hidden buttons remain here so they can be restored.")
                }

                Section {
                    Button("Restore default buttons and order", systemImage: "arrow.counterclockwise") {
                        configuration.resetToDefaults()
                    }
                }
            }
            .navigationTitle("Terminal keys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for key: TerminalKey) -> some View {
        if key.isPinned {
            HStack {
                Text(key.title)
                Spacer()
                Text("Always shown")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            Toggle(key.title, isOn: Binding(
                get: { configuration.isVisible(key) },
                set: { configuration.setVisible($0, for: key) }
            ))
        }
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
