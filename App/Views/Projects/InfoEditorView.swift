import SwiftUI

/// Edit the produced app's `Info.plist` settings before packaging.
struct InfoEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var info: AppInfo
    let onSave: (AppInfo) -> Void

    init(initial: AppInfo, onSave: @escaping (AppInfo) -> Void) {
        self.onSave = onSave
        _info = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Bundle Identifier", text: $info.bundleIdentifier)
                        .keyboardType(.alphabet).autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Display Name", text: $info.displayName)
                }
                Section("Version") {
                    TextField("Marketing Version", text: $info.version)
                        .keyboardType(.decimalPad)
                    TextField("Build Number", text: $info.buildNumber)
                        .keyboardType(.numberPad)
                }
                Section("Deployment") {
                    TextField("Minimum iOS", text: $info.minimumOSVersion)
                        .keyboardType(.decimalPad)
                }
                Section {
                    Text("These become the Info.plist of the built .ipa.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("App Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(info); dismiss() }
                }
            }
        }
    }
}
