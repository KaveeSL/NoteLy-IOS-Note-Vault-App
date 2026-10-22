import SwiftUI

/// Everyday notes settings. This screen matches the Notes settings people expect and does not describe a hidden area.
struct NotesSettingsView: View {
    @ObservedObject var viewModel: NotesListViewModel
    @ObservedObject private var preferences = NotesPreferences.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("On My iPhone", value: "On")
            } header: {
                Text("Accounts")
            } footer: {
                Text("Notes stay on this iPhone. iCloud, Exchange, Google, and Yahoo accounts are not connected.")
            }

            Section("Viewing") {
                Picker("Sort Notes By", selection: $viewModel.sort) {
                    ForEach(NoteSort.allCases) { sort in
                        Text(sort.rawValue).tag(sort)
                    }
                }
                Toggle("Group By Date", isOn: $viewModel.groupByDate)
                Picker("Lines & Grids", selection: $preferences.paper) {
                    ForEach(PaperStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
            }

            Section {
                LabeledContent("Version", value: "1.0")
            } footer: {
                Text("NoteLy keeps your notes on this device and does not send note contents anywhere.")
            }

        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
