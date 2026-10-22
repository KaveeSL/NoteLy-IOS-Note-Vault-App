import AVFoundation
import PDFKit
import Speech
import SwiftUI
import UIKit
import Vision
import VisionKit

enum PaperStyle: String, CaseIterable, Identifiable {
    case plain = "Default"
    case lines = "Lines"
    case grid = "Grid"
    var id: String { rawValue }
}

struct SmartFolder: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var tag: String = ""
    var pinnedOnly = false
    var withAttachments = false
    var withChecklists = false
    var lockedOnly = false
}

@MainActor
final class NotesPreferences: ObservableObject {
    static let shared = NotesPreferences()
    @Published var paper: PaperStyle {
        didSet { defaults.set(paper.rawValue, forKey: paperKey) }
    }
    @Published var smartFolders: [SmartFolder] {
        didSet { persistFolders() }
    }

    private let defaults = UserDefaults.standard
    private let paperKey = "notely.paper"
    private let foldersKey = "notely.smartFolders"

    private init() {
        paper = PaperStyle(rawValue: UserDefaults.standard.string(forKey: paperKey) ?? "") ?? .plain
        if let data = UserDefaults.standard.data(forKey: foldersKey),
           let decoded = try? JSONDecoder().decode([SmartFolder].self, from: data) {
            smartFolders = decoded
        } else {
            smartFolders = []
        }
    }

    private func persistFolders() {
        if let data = try? JSONEncoder().encode(smartFolders) {
            defaults.set(data, forKey: foldersKey)
        }
    }
}

enum NoteLocks {
    private static let key = "notely.lockedNotes"

    static func contains(_ id: UUID) -> Bool {
        ids().contains(id.uuidString)
    }

    static func set(_ id: UUID, locked: Bool) {
        var current = ids()
        if locked {
            current.insert(id.uuidString)
        } else {
            current.remove(id.uuidString)
        }
        UserDefaults.standard.set(Array(current), forKey: key)
    }

    private static func ids() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }
}

struct PaperBackground: View {
    var style: PaperStyle

    var body: some View {
        Canvas { context, size in
            guard style != .plain else { return }
            let color = GraphicsContext.Shading.color(Color.secondary.opacity(0.22))
            if style == .lines || style == .grid {
                var y: CGFloat = 52
                while y < size.height {
                    var path = Path()
                    path.move(to: CGPoint(x: 20, y: y))
                    path.addLine(to: CGPoint(x: size.width - 16, y: y))
                    context.stroke(path, with: color, lineWidth: 0.6)
                    y += 32
                }
            }
            if style == .grid {
                var x: CGFloat = 20
                while x < size.width {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 16))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: color, lineWidth: 0.6)
                    x += 32
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct NoteFormatBar: View {
    var onChecklist: () -> Void
    var onDrawing: () -> Void
    var styleMenu: AnyView
    var attachMenu: AnyView

    var body: some View {
        HStack(spacing: 4) {
            formatButton("checklist", "Checklist", onChecklist)
            styleMenu
            attachMenu
            formatButton("pencil.tip", "Drawing", onDrawing)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .notesGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func formatButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body)
                .frame(width: 44, height: 36)
        }
        .accessibilityLabel(label)
    }
}

struct LockedNoteCover: View {
    var unlock: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("This Note is Locked", systemImage: "lock.fill")
        } description: {
            Text("Use Face ID or your device passcode to view it.")
        } actions: {
            Button("View Note", action: unlock)
                .buttonStyle(.borderedProminent)
        }
    }
}

struct QuickNoteSheet: View {
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.title3)
                .padding(12)
                .background(PaperBackground(style: .lines))
                .navigationTitle("Quick Note")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            onSave(text)
                            dismiss()
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(28)
    }
}

struct EquationSheet: View {
    var onInsert: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var expression = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Equation", text: $expression)
                    .font(.system(.title3, design: .serif))
                    .textInputAutocapitalization(.never)
                Text("Example: E = mc^2")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Equation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Insert") {
                        onInsert(expression.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct LinkSheet: View {
    var notes: [Note]
    var onInsert: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var label = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Web link") {
                    TextField("Title", text: $label)
                    TextField("https://", text: $address)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }
                if !notes.isEmpty {
                    Section("Link to a note") {
                        ForEach(notes, id: \.persistentModelID) { note in
                            Button(note.title.isEmpty ? "New Note" : note.title) {
                                let title = note.title.isEmpty ? "New Note" : note.title
                                onInsert("\(title)")
                                dismiss()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { insertWeb() }
                        .disabled(URL(string: normalized) == nil || !normalized.contains("."))
                }
            }
        }
    }

    private var normalized: String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return trimmed }
        return "https://\(trimmed)"
    }

    private func insertWeb() {
        guard let url = URL(string: normalized) else { return }
        let title = label.trimmingCharacters(in: .whitespacesAndNewlines)
        onInsert(title.isEmpty ? url.absoluteString : "\(title) \(url.absoluteString)")
        dismiss()
    }
}

struct SmartFolderSheet: View {
    var onCreate: (SmartFolder) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var tag = ""
    @State private var pinnedOnly = false
    @State private var withAttachments = false
    @State private var withChecklists = false
    @State private var lockedOnly = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Tag", text: $tag)
                Toggle("Pinned", isOn: $pinnedOnly)
                Toggle("With attachments", isOn: $withAttachments)
                Toggle("With checklists", isOn: $withChecklists)
                Toggle("Locked", isOn: $lockedOnly)
            }
            .navigationTitle("New Smart Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let result = InputValidators.folderName(name, existing: [])
                        guard case .valid(let folderName) = result else { return }
                        let parsed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                        let tagValue = parsed.isEmpty ? "" : (InputValidators.tag(parsed).value ?? "")
                        onCreate(SmartFolder(
                            name: folderName,
                            tag: tagValue,
                            pinnedOnly: pinnedOnly,
                            withAttachments: withAttachments,
                            withChecklists: withChecklists,
                            lockedOnly: lockedOnly
                        ))
                        dismiss()
                    }
                    .disabled(InputValidators.folderName(name, existing: []).value == nil)
                }
            }
        }
    }
}

extension ValidationResult {
    var value: Value? {
        if case .valid(let value) = self { return value }
        return nil
    }
}

struct ActivityShareView: UIViewControllerRepresentable {
    var items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

enum NotePrinter {
    static func print(title: String, body: String) {
        let safeTitle = title.isEmpty ? "Note" : title
        let markup = "<h1>\(escape(safeTitle))</h1><pre>\(escape(body))</pre>"
        let formatter = UIMarkupTextPrintFormatter(markupText: markup)
        let controller = UIPrintInteractionController.shared
        controller.printFormatter = formatter
        controller.present(animated: true)
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

struct PDFAttachmentView: View {
    var data: Data
    var title: String

    var body: some View {
        PDFKitView(data: data)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PDFKitView: UIViewRepresentable {
    var data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(data: data)
        view.backgroundColor = .systemBackground
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}
}

struct ScanTextCamera: UIViewControllerRepresentable {
    var onText: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onText: onText, dismiss: dismiss) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onText: (String) -> Void
        let dismiss: DismissAction
        init(onText: @escaping (String) -> Void, dismiss: DismissAction) {
            self.onText = onText
            self.dismiss = dismiss
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { dismiss() }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = (info[.originalImage] as? UIImage) ?? UIImage()
            recognize(image)
            dismiss()
        }

        private func recognize(_ image: UIImage) {
            guard let cgImage = image.cgImage else { return }
            let request = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string } ?? []
                let text = lines.joined(separator: "\n")
                DispatchQueue.main.async { self.onText(text) }
            }
            request.recognitionLevel = .accurate
            let handler = VNImageRequestHandler(cgImage: cgImage)
            try? handler.perform([request])
        }
    }
}

@MainActor
final class AudioNoteRecorder: ObservableObject {
    @Published var transcript = ""
    @Published var isRecording = false
    @Published var seconds = 0
    @Published var message: String?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var file: AVAudioFile?
    private var timer: Timer?
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")

    func toggle() {
        if isRecording { stop() } else { begin() }
    }

    func begin() {
        AVAudioSession.sharedInstance().requestRecordPermission { allowed in
            Task { @MainActor in
                guard allowed else {
                    self.message = "The microphone is turned off for NoteLy."
                    return
                }
                SFSpeechRecognizer.requestAuthorization { status in
                    Task { @MainActor in
                        self.startEngine(transcribe: status == .authorized)
                    }
                }
            }
        }
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        timer?.invalidate()
        isRecording = false
    }

    func fileData() -> Data? {
        try? Data(contentsOf: url)
    }

    private func startEngine(transcribe: Bool) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            file = try AVAudioFile(forWriting: url, settings: format.settings)
            if transcribe, let recognizer = SFSpeechRecognizer(), recognizer.isAvailable {
                request = SFSpeechAudioBufferRecognitionRequest()
                request?.shouldReportPartialResults = true
                if let request {
                    task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
                        guard let text = result?.bestTranscription.formattedString else { return }
                        Task { @MainActor in self?.transcript = text }
                    }
                }
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                try? self?.file?.write(from: buffer)
                self?.request?.append(buffer)
            }
            engine.prepare()
            try engine.start()
            isRecording = true
            seconds = 0
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.seconds += 1 }
            }
        } catch {
            message = "Recording couldn't start."
        }
    }
}

struct AudioNoteSheet: View {
    var onFinish: (Data?, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = AudioNoteRecorder()

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text(timeLabel)
                    .font(.system(size: 44, weight: .medium, design: .rounded))
                    .monospacedDigit()
                Text(recorder.transcript.isEmpty ? "Transcript appears here while you speak." : recorder.transcript)
                    .font(.body)
                    .foregroundStyle(recorder.transcript.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .notesGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                if let message = recorder.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                Button {
                    recorder.toggle()
                } label: {
                    Image(systemName: recorder.isRecording ? "stop.fill" : "record.circle")
                        .font(.system(size: 64))
                        .foregroundStyle(recorder.isRecording ? Color.red : Theme.accent)
                }
                .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Record")
                Spacer()
            }
            .padding(20)
            .navigationTitle("Record Audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        recorder.stop()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        recorder.stop()
                        onFinish(recorder.fileData(), recorder.transcript)
                        dismiss()
                    }
                }
            }
        }
    }

    private var timeLabel: String {
        String(format: "%d:%02d", recorder.seconds / 60, recorder.seconds % 60)
    }
}
