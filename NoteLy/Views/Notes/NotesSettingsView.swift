import SwiftUI
import UIKit

/// Everyday notes settings. This screen matches the Notes settings people expect and does not describe a hidden area.
struct NotesSettingsView: View {
    @ObservedObject var viewModel: NotesListViewModel
    @ObservedObject private var preferences = NotesPreferences.shared
    @EnvironmentObject private var appState: AppState

    @State private var versionTaps = 0
    @State private var lastVersionTap: Date?
    @State private var showingChange = false
    @State private var needsCode = false
    @State private var codeDigits = ""
    @State private var codeMessage = ""
    @State private var newPhrase = ""
    @State private var phraseConfirm = ""
    @State private var showPhrase = false
    @State private var phraseMessage = ""
    @State private var notice = ""
    @State private var showingNotice = false
    @State private var showingVersionHint = false
    @State private var versionHintTask: Task<Void, Never>?

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

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
                HStack(spacing: 0) {
                    Button(action: versionTapped) {
                        HStack {
                            Text("Version")
                            Spacer(minLength: 8)
                            Text(appVersion)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.version")
                    Button(action: showVersionHint) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Version info")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if showingVersionHint {
                        Text("Tap Version 10 times to change the phrase.")
                    }
                    Text("NoteLy keeps your notes on this device and does not send note contents anywhere.")
                }
            }

            Section {
                Text("© 2026 DK Technologies Inc.")
                    .font(.footnote)
                    .foregroundStyle(Color(.tertiaryLabel))
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingChange, onDismiss: resetChange) {
            NavigationStack {
                if needsCode {
                    codeEntry
                } else {
                    phraseEntry
                }
            }
            .tint(Theme.accent)
        }
        .alert("Phrase updated", isPresented: $showingNotice) {
            Button("OK") {}
                .tint(Color(red: 0.0, green: 0.45, blue: 1))
        } message: {
            Text(notice)
        }
        .tint(Theme.accent)
        .onAppear {
            #if DEBUG
            if UITestHooks.showFilledPhrase {
                needsCode = false
                showPhrase = true
                showingChange = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    showPhrase = true
                    newPhrase = "bright-harbor"
                    phraseConfirm = "bright-harbor"
                }
            }
            #endif
        }
        .onDisappear {
            versionTaps = 0
            lastVersionTap = nil
            versionHintTask?.cancel()
            showingVersionHint = false
        }
    }

    private var codeEntry: some View {
        VStack(spacing: 22) {
            Text("Enter your 6-digit code.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 14) {
                ForEach(0..<6, id: \.self) { index in
                    Circle()
                        .fill(index < codeDigits.count ? Theme.accent : Color.secondary.opacity(0.25))
                        .frame(width: 14, height: 14)
                }
            }
            .accessibilityLabel("\(codeDigits.count) of 6 digits")
            if !codeMessage.isEmpty {
                Text(codeMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 14) {
                ForEach(1...9, id: \.self) { number in
                    digit("\(number)")
                }
                digit("clear")
                digit("0")
                digit("delete")
            }
            .frame(maxWidth: 280)
            Spacer(minLength: 0)
        }
        .padding(.top, 28)
        .padding(.horizontal, 24)
        .navigationTitle("Enter Code")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { showingChange = false }
            }
        }
    }

    private var phraseEntry: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                phraseHint("magnifyingglass", "Type it in Search when you want to open it.")
                phraseHint("eye.slash", "Pick words you would never use for a note.")
                PlainTextBox(title: "New phrase", text: $newPhrase, secure: !showPhrase)
                    .onChange(of: newPhrase) { _, _ in phraseMessage = "" }
                PlainTextBox(title: "Type it again", text: $phraseConfirm, secure: !showPhrase)
                    .onChange(of: phraseConfirm) { _, _ in phraseMessage = "" }
                Toggle("Show phrase", isOn: $showPhrase)
                    .font(.body)
                PhraseStrengthMeter(phrase: newPhrase)
                if let note = livePhraseNote {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
                Text("If you forget the new phrase, it can't be recovered.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("New phrase")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { showingChange = false }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await savePhrase() } }
                    .disabled(!phraseReady || appState.settings.isWorking)
            }
        }
        .privacySensitive()
    }

    private func phraseHint(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 22, alignment: .center)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var phraseReady: Bool {
        if case .invalid = PhraseValidator.validate(newPhrase) { return false }
        return PhraseValidator.normalize(newPhrase) == PhraseValidator.normalize(phraseConfirm) && !phraseConfirm.isEmpty
    }

    private var livePhraseNote: String? {
        if !phraseMessage.isEmpty { return phraseMessage }
        if newPhrase.isEmpty { return nil }
        if case .invalid(let reason) = PhraseValidator.validate(newPhrase) { return reason }
        if !phraseConfirm.isEmpty, PhraseValidator.normalize(newPhrase) != PhraseValidator.normalize(phraseConfirm) {
            return "Those phrases don't match."
        }
        return nil
    }

    private func digit(_ label: String) -> some View {
        Button {
            press(label)
        } label: {
            Group {
                if label == "delete" {
                    Image(systemName: "delete.left")
                } else if label == "clear" {
                    Image(systemName: "xmark")
                } else {
                    Text(label).font(.title2)
                }
            }
            .frame(width: 72, height: 64)
            .notesGlass(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label == "delete" ? "Delete" : (label == "clear" ? "Clear" : label))
    }

    private func press(_ label: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if label == "clear" {
            codeDigits = ""
            codeMessage = ""
            return
        }
        if label == "delete" {
            if !codeDigits.isEmpty { codeDigits.removeLast() }
            codeMessage = ""
            return
        }
        guard codeDigits.count < 6 else { return }
        codeDigits.append(label)
        guard codeDigits.count == 6 else { return }
        let entered = codeDigits
        codeDigits = ""
        switch appState.unlockCodeAvailability() {
        case .coolingDown:
            showingChange = false
            notice = "Try again in a few minutes."
            showingNotice = true
        case .missing:
            showingChange = false
            notice = "Finish setup before changing the phrase."
            showingNotice = true
        case .ready:
            if appState.unlockCodeMatches(entered) {
                needsCode = false
                codeMessage = ""
            } else if appState.unlockCodeAvailability() == .coolingDown {
                showingChange = false
                notice = "Try again in a few minutes."
                showingNotice = true
            } else {
                codeMessage = "That code doesn't match."
            }
        }
    }

    private func showVersionHint() {
        showingVersionHint = true
        versionHintTask?.cancel()
        versionHintTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            showingVersionHint = false
        }
    }

    private func versionTapped() {
        let now = Date()
        if let lastVersionTap, now.timeIntervalSince(lastVersionTap) > 4 {
            versionTaps = 0
        }
        lastVersionTap = now
        versionTaps += 1
        guard versionTaps >= 10 else { return }
        versionTaps = 0
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task { await openPhraseChange() }
    }

    private func openPhraseChange() async {
        switch await appState.confirmWithFaceID() {
        case .allowed:
            needsCode = false
            showingChange = true
        case .cancelled:
            break
        case .needCode:
            switch appState.unlockCodeAvailability() {
            case .ready:
                codeDigits = ""
                codeMessage = ""
                needsCode = true
                showingChange = true
            case .missing:
                notice = "Finish setup before changing the phrase."
                showingNotice = true
            case .coolingDown:
                notice = "Try again in a few minutes."
                showingNotice = true
            }
        }
    }

    private func savePhrase() async {
        if let problem = await appState.settings.replacePhrase(newPhrase: newPhrase, confirmation: phraseConfirm) {
            phraseMessage = problem
            return
        }
        showingChange = false
        notice = "Phrase updated. Search will use the new one."
        showingNotice = true
    }

    private func resetChange() {
        needsCode = false
        codeDigits = ""
        codeMessage = ""
        newPhrase = ""
        phraseConfirm = ""
        showPhrase = false
        phraseMessage = ""
    }
}
