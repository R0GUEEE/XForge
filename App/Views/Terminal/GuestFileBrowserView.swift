import SwiftUI
import UIKit

private final class GuestListingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func append(_ chunk: String) { lock.lock(); value += chunk; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return value }
}

/// File explorer for the actual Alpine filesystem.
struct GuestFileBrowserView: View {
    @State private var path: String
    @State private var entries: [Entry] = []
    @State private var loading = false
    @State private var error: String?
    @State private var vm: (any LinuxVM)?
    @State private var showHidden = false
    @State private var pendingAction: FileAction?
    @State private var destination = ""
    @State private var deleteTarget: Entry?
    @Environment(\.dismiss) private var dismiss

    struct Entry: Identifiable, Hashable {
        let name: String
        let path: String
        let isDirectory: Bool
        let size: Int64
        var id: String { path }
    }

    enum FileAction: Identifiable {
        case copy(Entry), move(Entry)
        var id: String {
            switch self { case .copy(let e): return "copy:" + e.path; case .move(let e): return "move:" + e.path }
        }
        var title: String { switch self { case .copy: return "Copy"; case .move: return "Move" } }
        var entry: Entry { switch self { case .copy(let e), .move(let e): return e } }
    }

    init(path: String = "/") { _path = State(initialValue: path) }

    var body: some View {
        NavigationStack {
            List {
                if path != "/" {
                    Button { navigate(to: parent(path)) } label: {
                        Label("..", systemImage: "arrow.turn.up.left")
                    }
                }
                if loading { ProgressView("Reading \(path)…") }
                if let error {
                    ContentUnavailableViewCompat(title: "Could Not Read Folder",
                                                  systemImage: "exclamationmark.triangle",
                                                  message: error)
                }
                ForEach(entries) { entry in row(entry) }
            }
            .navigationTitle(path)
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await load() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Toggle("Show Hidden Files", isOn: $showHidden)
                        Button("Copy Current Path", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = path
                        }
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onChange(of: showHidden) { _ in Task { await load() } }
            .task { await load() }
            .alert(pendingAction?.title ?? "File Action",
                   isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } })) {
                TextField("Destination path", text: $destination)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) { pendingAction = nil }
                Button(pendingAction?.title ?? "Apply") {
                    guard let action = pendingAction else { return }
                    Task { await perform(action) }
                }
            } message: {
                Text("Enter an absolute Alpine path or a destination directory.")
            }
            .confirmationDialog("Delete \(deleteTarget?.name ?? "item")?",
                                isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    guard let target = deleteTarget else { return }
                    Task { await remove(target) }
                }
                Button("Cancel", role: .cancel) { deleteTarget = nil }
            }
        }
    }

    @ViewBuilder private func row(_ entry: Entry) -> some View {
        Button {
            if entry.isDirectory { navigate(to: entry.path) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: entry.isDirectory ? "folder.fill" : icon(entry.name))
                    .foregroundStyle(entry.isDirectory ? .tint : .secondary)
                VStack(alignment: .leading) {
                    Text(entry.name).lineLimit(1)
                    if !entry.isDirectory {
                        Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if entry.isDirectory { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = entry.path }
            Button("Copy…", systemImage: "plus.square.on.square") { begin(.copy(entry)) }
            Button("Move…", systemImage: "folder") { begin(.move(entry)) }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = entry }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleteTarget = entry } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func begin(_ action: FileAction) {
        pendingAction = action
        destination = path
    }

    private func navigate(to value: String) {
        path = value.hasPrefix("/") ? value : "/" + value
        Task { await load() }
    }

    private func load() async {
        loading = true; error = nil
        do {
            let guest = vm ?? XForgeEnvironment.makeVM()
            vm = guest
            try await guest.boot()
            let box = GuestListingBox()
            let hiddenGlob = showHidden ? " \(GuestShell.quote(path))/.[!.]*" : ""
            let listing = """
            for item in \(GuestShell.quote(path))/*\(hiddenGlob); do
                [ -e "$item" ] || [ -L "$item" ] || continue
                if [ -d "$item" ]; then kind=d; else kind=f; fi
                size=$(stat -c %s "$item" 2>/dev/null || echo 0)
                printf '%s\\t%s\\t%s\\n' "$kind" "$item" "$size"
            done | sort -k2
            """
            let status = try await guest.run(listing, environment: nil) { box.append($0) }
            guard status == 0 else { throw BrowserError.operationFailed("The guest could not list this folder.") }
            entries = box.text.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
                guard parts.count == 3 else { return nil }
                let full = parts[1]
                return Entry(name: URL(fileURLWithPath: full).lastPathComponent,
                             path: full, isDirectory: parts[0] == "d", size: Int64(parts[2]) ?? 0)
            }
        } catch { self.error = error.localizedDescription }
        loading = false
    }

    private func perform(_ action: FileAction) async {
        let target = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard target.hasPrefix("/") else {
            error = "Destination must be an absolute Alpine path."; pendingAction = nil; return
        }
        do {
            let guest = vm ?? XForgeEnvironment.makeVM()
            vm = guest
            let verb = action.title == "Copy" ? "cp -R" : "mv"
            let command = "\(verb) -- \(GuestShell.quote(action.entry.path)) \(GuestShell.quote(target))"
            let status = try await guest.run(command, environment: nil) { _ in }
            guard status == 0 else { throw BrowserError.operationFailed("\(action.title) failed.") }
            pendingAction = nil
            await load()
        } catch { self.error = error.localizedDescription; pendingAction = nil }
    }

    private func remove(_ entry: Entry) async {
        do {
            let guest = vm ?? XForgeEnvironment.makeVM()
            vm = guest
            let status = try await guest.run("rm -rf -- \(GuestShell.quote(entry.path))", environment: nil) { _ in }
            guard status == 0 else { throw BrowserError.operationFailed("Delete failed.") }
            deleteTarget = nil
            await load()
        } catch { self.error = error.localizedDescription; deleteTarget = nil }
    }

    private func parent(_ value: String) -> String {
        let p = (value as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }

    private func icon(_ name: String) -> String {
        if name.hasSuffix(".ipa") { return "app.badge" }
        if name.hasSuffix(".zip") || name.hasSuffix(".tar.gz") { return "archivebox" }
        if name.hasSuffix(".dylib") { return "shippingbox" }
        return "doc"
    }

    enum BrowserError: LocalizedError {
        case operationFailed(String)
        var errorDescription: String? { if case .operationFailed(let message) = self { return message }; return nil }
    }
}
