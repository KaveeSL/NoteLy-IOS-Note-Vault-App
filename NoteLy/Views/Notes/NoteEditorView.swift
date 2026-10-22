import PencilKit
import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VisionKit

struct NoteEditorView: View {
    @Bindable var note: Note
    var folders: [NoteFolder] = []
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @Query(sort: \Note.updatedAt, order: .reverse) private var allNotes: [Note]
    @ObservedObject private var preferences = NotesPreferences.shared
    @StateObject private var editor = RichTextController()
    @State private var findText = ""
    @State private var showFind = false
    @State private var showDrawing = false
    @State private var showScanner = false
    @State private var showFiles = false
    @State private var showAudio = false
    @State private var showEquation = false
    @State private var showLink = false
    @State private var showShare = false
    @State private var showScanText = false
    @State private var showMove = false
    @State private var unlocked = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var saveError: String?
    @State private var pdfAttachment: NoteAttachment?
    @State private var showAttach = false
    @State private var showPhotos = false

    var body: some View {
        Group {
            if NoteLocks.contains(note.id) && !unlocked {
                LockedNoteCover {
                    Task { await unlock() }
                }
            } else {
                writing
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .onDisappear {
            editor.flush(into: note)
            removeIfEmpty()
            try? modelContext.save()
        }
        .sheet(isPresented: $showDrawing) {
            MarkupCanvasView(data: note.drawingData) { data in
                note.drawingData = data
                note.updatedAt = .now
                try? modelContext.save()
            }
        }
        .sheet(isPresented: $showScanner) {
            DocumentScannerView { images in
                attachImages(images, prefix: "Scan")
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                attachFiles(urls)
            }
        }
        .onChange(of: photoItems) { _, items in
            Task { await attachPhotos(items) }
        }
        .sheet(isPresented: $showAudio) {
            AudioNoteSheet { data, transcript in
                if let data {
                    let attachment = NoteAttachment(typeRaw: "audio", fileName: "Recording.caf", payload: data)
                    attachment.note = note
                    modelContext.insert(attachment)
                }
                if !transcript.isEmpty { editor.insert("\n" + transcript) }
                try? modelContext.save()
            }
        }
        .sheet(isPresented: $showEquation) {
            EquationSheet { editor.insert("\n" + $0 + "\n") }
        }
        .sheet(isPresented: $showLink) {
            LinkSheet(notes: allNotes.filter { $0.id != note.id && $0.deletedAt == nil }) { editor.insert($0) }
        }
        .sheet(isPresented: $showShare) {
            ActivityShareView(items: [shareText])
        }
        .sheet(isPresented: $showScanText) {
            ScanTextCamera { text in
                if !text.isEmpty { editor.insert("\n" + text) }
            }
        }
        .sheet(isPresented: $showMove) {
            NavigationStack {
                List(folders) { folder in
                    Button(folder.name) {
                        note.folder = folder
                        try? modelContext.save()
                        showMove = false
                    }
                }
                .navigationTitle("Move Note")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $pdfAttachment) { attachment in
            if let data = attachment.payload {
                PDFAttachmentView(data: data, title: attachment.fileName)
            }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, matching: .any(of: [.images, .videos]))
        .confirmationDialog("Add to note", isPresented: $showAttach, titleVisibility: .visible) {
            Button("Photo or Video") { showPhotos = true }
            Button("Scan Documents") { showScanner = true }
            Button("Scan Text") { showScanText = true }
            Button("Record Audio") { showAudio = true }
            Button("Attach File") { showFiles = true }
            Button("Drawing") { showDrawing = true }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't save this note", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "Try again.")
        }
    }

    private var writing: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.updatedAt.formatted(date: .long, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                if let attachments = note.attachments, !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(attachments, id: \.persistentModelID) { attachment in
                                Button(attachment.fileName.isEmpty ? attachment.typeRaw : attachment.fileName) {
                                    if attachment.fileName.lowercased().hasSuffix(".pdf") || attachment.typeRaw == "pdf" {
                                        pdfAttachment = attachment
                                    }
                                }
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .notesGlass(in: Capsule())
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            ZStack {
                PaperBackground(style: preferences.paper)
                RichTextView(note: note, controller: editor, onAttach: { showAttach = true }, onTable: {
                    editor.insert("\nA\tB\n1\t2\n")
                })
            }
            if showFind {
                HStack {
                    TextField("Find", text: $findText)
                        .textFieldStyle(.roundedBorder)
                    Button("Next") { editor.find(findText, forward: true) }
                    Button("Previous") { editor.find(findText, forward: false) }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .background(Color(.systemBackground))
    }

    private var styleMenu: some View {
        Menu {
            Button("Title") { editor.applyStyle(.title) }
            Button("Heading") { editor.applyStyle(.heading) }
            Button("Subheading") { editor.applyStyle(.subheading) }
            Button("Body") { editor.applyStyle(.body) }
            Button("Monospaced") { editor.applyStyle(.mono) }
            Divider()
            Button("Bold") { editor.toggleTrait(.traitBold) }
            Button("Italic") { editor.toggleTrait(.traitItalic) }
            Button("Underline") { editor.toggleUnderline() }
            Button("Strikethrough") { editor.toggleStrikethrough() }
            Button("Highlight") { editor.toggleHighlight() }
            Divider()
            Button("Bulleted List") { editor.insertList(prefix: "• ") }
            Button("Numbered List") { editor.insertList(prefix: "1. ") }
            Button("Table") { editor.insert("\n\t\t\n\t\t\n") }
        } label: {
            Image(systemName: "textformat")
                .font(.body)
                .frame(width: 44, height: 36)
        }
        .accessibilityLabel("Format")
    }

    private var attachMenu: some View {
        Menu {
            PhotosPicker(selection: $photoItems, matching: .any(of: [.images, .videos])) {
                Label("Photo or Video", systemImage: "photo")
            }
            Button("Scan Documents", systemImage: "doc.viewfinder") { showScanner = true }
            Button("Scan Text", systemImage: "text.viewfinder") { showScanText = true }
            Button("Record Audio", systemImage: "mic") { showAudio = true }
            Button("Attach File", systemImage: "paperclip") { showFiles = true }
        } label: {
            Image(systemName: "camera")
                .font(.body)
                .frame(width: 44, height: 36)
        }
        .accessibilityLabel("Add")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button { showShare = true } label: { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Share")
            Menu {
                Button(note.isPinned ? "Unpin" : "Pin") { note.isPinned.toggle() }
                Button(NoteLocks.contains(note.id) ? "Remove Lock" : "Lock") {
                    let locked = !NoteLocks.contains(note.id)
                    NoteLocks.set(note.id, locked: locked)
                    if locked { unlocked = false }
                }
                Button("Find in Note") { showFind.toggle() }
                Button("Move") { showMove = true }
                Button("Add Link") { showLink = true }
                Button("Equation") { showEquation = true }
                Menu("Lines & Grids") {
                    Picker("Paper", selection: $preferences.paper) {
                        ForEach(PaperStyle.allCases) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                }
                Button("Print") { NotePrinter.print(title: note.title, body: editor.plainText) }
                Button("Word count: \(editor.plainText.split(whereSeparator: \.isWhitespace).filter { !$0.isEmpty }.count)") {}
                Button("Undo") { editor.undo() }
                Button("Redo") { editor.redo() }
                if note.deletedAt != nil {
                    Text("Deleted \(note.deletedAt?.formatted(date: .abbreviated, time: .omitted) ?? "")")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            Button(action: finishEditing) {
                Image(systemName: "checkmark")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Theme.accent, in: Circle())
            }
            .accessibilityLabel("Done")
        }
    }

    private func finishEditing() {
        editor.flush(into: note)
        try? modelContext.save()
        dismiss()
    }

    private var shareText: String {
        [note.title, editor.plainText].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func unlock() async {
        let outcome = await appState.biometric.authenticate(reason: UnlockPrompt.reason)
        if case .success = outcome {
            unlocked = true
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
    }

    private func removeIfEmpty() {
        let attachments = note.attachments?.count ?? 0
        if InputValidators.noteIsEmpty(
            title: note.title,
            body: note.body,
            attachmentCount: attachments,
            hasDrawing: note.drawingData != nil
        ) {
            modelContext.delete(note)
        }
    }

    private func attachPhotos(_ items: [PhotosPickerItem]) async {
        var bytes = note.attachments?.reduce(0) { $0 + ($1.payload?.count ?? 0) } ?? 0
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                bytes += data.count
                guard InputValidators.withinNoteBudget(textBytes: note.plainText.utf8.count, attachmentBytes: bytes) else {
                    saveError = "This note is too large to add that attachment."
                    break
                }
                let attachment = NoteAttachment(typeRaw: "photo", fileName: "Photo", payload: data, thumbnail: data)
                attachment.note = note
                modelContext.insert(attachment)
            }
        }
        note.updatedAt = .now
        try? modelContext.save()
        photoItems = []
    }

    private func attachImages(_ images: [UIImage], prefix: String) {
        for (index, image) in images.enumerated() {
            guard let data = image.jpegData(compressionQuality: 0.85) else { continue }
            let attachment = NoteAttachment(typeRaw: "scan", fileName: "\(prefix) \(index + 1)", payload: data, thumbnail: data)
            attachment.note = note
            modelContext.insert(attachment)
        }
        note.updatedAt = .now
        try? modelContext.save()
    }

    private func attachFiles(_ urls: [URL]) {
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let attachment = NoteAttachment(
                typeRaw: "file",
                fileName: InputValidators.sanitizedFilename(url.lastPathComponent),
                payload: data
            )
            attachment.note = note
            modelContext.insert(attachment)
        }
        note.updatedAt = .now
        try? modelContext.save()
    }
}

enum NoteTextStyle {
    case title, heading, subheading, body, mono
}

@MainActor
final class RichTextController: ObservableObject {
    weak var textView: UITextView?
    private var saveHandler: ((String, Data?) -> Void)?

    var plainText: String { textView?.text ?? "" }

    func bind(save: @escaping (String, Data?) -> Void) {
        saveHandler = save
    }

    func flush(into note: Note) {
        let text = textView?.text ?? note.body
        note.plainText = text
        note.title = InputValidators.noteTitle(from: text)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        note.body = lines.dropFirst().joined(separator: "\n")
        note.tags = Self.tags(in: text)
        if let view = textView, let data = try? view.attributedText.data(
            from: NSRange(location: 0, length: view.attributedText.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) {
            note.richContent = data
        }
        note.updatedAt = .now
    }

    func textDidChange() {
        guard let textView else { return }
        let text = textView.text ?? ""
        let rtf = try? textView.attributedText.data(
            from: NSRange(location: 0, length: textView.attributedText.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        saveHandler?(text, rtf)
    }

    func applyStyle(_ style: NoteTextStyle) {
        let size: CGFloat
        let mono: Bool
        switch style {
        case .title: size = 28; mono = false
        case .heading: size = 22; mono = false
        case .subheading: size = 18; mono = false
        case .body: size = 17; mono = false
        case .mono: size = 16; mono = true
        }
        let font = mono ? UIFont.monospacedSystemFont(ofSize: size, weight: .regular) : UIFont.systemFont(ofSize: size)
        updateAttributes { _ in [.font: font] }
    }

    func toggleTrait(_ trait: UIFontDescriptor.SymbolicTraits) {
        updateAttributes { current in
            let font = (current[.font] as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
            var traits = font.fontDescriptor.symbolicTraits
            if traits.contains(trait) { traits.remove(trait) } else { traits.insert(trait) }
            let descriptor = font.fontDescriptor.withSymbolicTraits(traits) ?? font.fontDescriptor
            return [.font: UIFont(descriptor: descriptor, size: font.pointSize)]
        }
    }

    func toggleUnderline() {
        updateAttributes { current in
            let value = (current[.underlineStyle] as? Int) == NSUnderlineStyle.single.rawValue ? 0 : NSUnderlineStyle.single.rawValue
            return [.underlineStyle: value]
        }
    }

    func toggleStrikethrough() {
        updateAttributes { current in
            let value = (current[.strikethroughStyle] as? Int) == NSUnderlineStyle.single.rawValue ? 0 : NSUnderlineStyle.single.rawValue
            return [.strikethroughStyle: value]
        }
    }

    func toggleHighlight() {
        updateAttributes { current in
            let yellow = UIColor.systemYellow.withAlphaComponent(0.55)
            let color = current[.backgroundColor] as? UIColor
            let isOn = color != nil && color != UIColor.clear && (color?.cgColor.alpha ?? 0) > 0.05
            return [.backgroundColor: isOn ? UIColor.clear : yellow]
        }
    }

    func setTextColor(_ color: UIColor) {
        updateAttributes { _ in [.foregroundColor: color] }
    }

    func insertChecklist() {
        guard let textView else { return }
        let ns = (textView.text ?? "") as NSString
        let line = ns.lineRange(for: textView.selectedRange)
        let current = ns.substring(with: line)
        let replacement: String
        if current.hasPrefix("● ") {
            replacement = "○ " + current.dropFirst(2)
        } else if current.hasPrefix("○ ") {
            replacement = "● " + current.dropFirst(2)
        } else {
            replacement = "○ " + current
        }
        textView.textStorage.replaceCharacters(in: line, with: replacement)
        var location = line.location + (replacement as NSString).length
        if replacement.hasSuffix("\n") { location -= 1 }
        location = min(max(location, 0), textView.textStorage.length)
        textView.selectedRange = NSRange(location: location, length: 0)
        textDidChange()
    }
    func insertList(prefix: String) { textView?.insertText(prefix) }
    func insert(_ text: String) { textView?.insertText(text) }

    func undo() { textView?.undoManager?.undo() }
    func redo() { textView?.undoManager?.redo() }

    func find(_ query: String, forward: Bool) {
        guard let textView, !query.isEmpty else { return }
        let text = textView.text ?? ""
        let ns = text as NSString
        let start = forward ? textView.selectedRange.upperBound : 0
        let range: NSRange
        if forward {
            range = ns.range(of: query, options: .caseInsensitive, range: NSRange(location: start, length: ns.length - start))
        } else {
            let end = max(textView.selectedRange.location, 0)
            range = ns.range(of: query, options: [.caseInsensitive, .backwards], range: NSRange(location: 0, length: end))
        }
        guard range.location != NSNotFound else { return }
        textView.selectedRange = range
        textView.scrollRangeToVisible(range)
    }

    private func updateAttributes(_ transform: ([NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any]) {
        guard let textView else { return }
        let range = textView.selectedRange
        let storage = textView.textStorage
        if range.length == 0 {
            var typing = textView.typingAttributes
            let next = transform(typing)
            for (key, value) in next { typing[key] = value }
            textView.typingAttributes = typing
            return
        }
        storage.beginEditing()
        storage.enumerateAttributes(in: range) { attributes, subrange, _ in
            var next = attributes
            for (key, value) in transform(attributes) { next[key] = value }
            storage.setAttributes(next, range: subrange)
        }
        storage.endEditing()
        textDidChange()
    }

    static func tags(in text: String) -> [String] {
        let pattern = #"#([A-Za-z0-9_]{1,40})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return ns.substring(with: match.range(at: 1)).lowercased()
        }
    }
}

struct RichTextView: UIViewRepresentable {
    var note: Note
    @ObservedObject var controller: RichTextController
    var onAttach: () -> Void = {}
    var onTable: () -> Void = {}

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.backgroundColor = .clear
        view.tintColor = UIColor(Theme.accent)
        view.alwaysBounceVertical = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 24, right: 16)
        view.allowsEditingTextAttributes = true
        let accessory = FormatAccessory(frame: CGRect(x: 0, y: 0, width: 320, height: 52))
        accessory.controller = controller
        accessory.onAttach = { context.coordinator.onAttach() }
        accessory.onTable = { context.coordinator.onTable() }
        accessory.autoresizingMask = .flexibleWidth
        view.inputAccessoryView = accessory
        context.coordinator.accessory = accessory
        if let data = note.richContent,
           let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
           ) {
            view.attributedText = attributed
        } else {
            let combined = [note.title, note.body].filter { !$0.isEmpty }.joined(separator: "\n")
            view.text = combined
        }
        controller.textView = view
        controller.bind { text, rtf in
            note.plainText = text
            note.title = InputValidators.noteTitle(from: text)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            note.body = lines.dropFirst().joined(separator: "\n")
            note.tags = RichTextController.tags(in: text)
            note.richContent = rtf
            note.updatedAt = .now
        }
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        controller.textView = uiView
        if let accessory = uiView.inputAccessoryView as? FormatAccessory {
            accessory.controller = controller
            accessory.onAttach = onAttach
            accessory.onTable = onTable
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let controller: RichTextController
        var accessory: FormatAccessory?
        var onAttach: () -> Void = {}
        var onTable: () -> Void = {}
        init(controller: RichTextController) { self.controller = controller }
        func textViewDidChange(_ textView: UITextView) { controller.textDidChange() }
    }
}

/// Sits above the keyboard. UIKit buttons keep the text view as first responder, so bold, color, and highlight apply to the selection.
final class FormatAccessory: UIView {
    weak var controller: RichTextController?
    var onAttach: () -> Void = {}
    var onTable: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 4
        stack.distribution = .equalSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
        stack.addArrangedSubview(styleButton())
        stack.addArrangedSubview(plain("checklist", #selector(checklist)))
        stack.addArrangedSubview(plain("tablecells", #selector(table)))
        stack.addArrangedSubview(colorButton())
        stack.addArrangedSubview(plain("highlighter", #selector(highlight)))
        stack.addArrangedSubview(plain("paperclip", #selector(attach)))
    }

    required init?(coder: NSCoder) { nil }

    private func plain(_ symbol: String, _ action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.tintColor = .label
        button.addTarget(self, action: action, for: .touchUpInside)
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }

    private func styleButton() -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "textformat.size"), for: .normal)
        button.tintColor = .label
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [
            action("Title · 28", .title),
            action("Heading · 22", .heading),
            action("Subheading · 18", .subheading),
            action("Body · 17", .body),
            action("Monospaced · 16", .mono),
            UIAction(title: "Bold") { [weak self] _ in self?.controller?.toggleTrait(.traitBold) },
            UIAction(title: "Italic") { [weak self] _ in self?.controller?.toggleTrait(.traitItalic) },
            UIAction(title: "Underline") { [weak self] _ in self?.controller?.toggleUnderline() },
            UIAction(title: "Strikethrough") { [weak self] _ in self?.controller?.toggleStrikethrough() }
        ])
        return button
    }

    private func action(_ title: String, _ style: NoteTextStyle) -> UIAction {
        UIAction(title: title) { [weak self] _ in self?.controller?.applyStyle(style) }
    }

    private func colorButton() -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "paintpalette"), for: .normal)
        button.tintColor = .label
        button.showsMenuAsPrimaryAction = true
        let colors: [(String, UIColor)] = [
            ("Black", .label),
            ("Red", .systemRed),
            ("Orange", .systemOrange),
            ("Yellow", .systemYellow),
            ("Green", .systemGreen),
            ("Blue", .systemBlue),
            ("Purple", .systemPurple)
        ]
        button.menu = UIMenu(children: colors.map { name, color in
            UIAction(title: name) { [weak self] _ in self?.controller?.setTextColor(color) }
        })
        return button
    }

    @objc private func checklist() { controller?.insertChecklist() }
    @objc private func table() { onTable() }
    @objc private func highlight() { controller?.toggleHighlight() }
    @objc private func attach() { onAttach() }
}

struct MarkupCanvasView: View {
    var data: Data?
    var onSave: (Data?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var canvas = PKCanvasView()

    var body: some View {
        NavigationStack {
            MarkupRepresentable(canvas: canvas, data: data)
                .navigationTitle("Drawing")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            onSave(canvas.drawing.dataRepresentation())
                            dismiss()
                        }
                    }
                }
        }
    }
}

private struct MarkupRepresentable: UIViewRepresentable {
    let canvas: PKCanvasView
    var data: Data?

    func makeUIView(context: Context) -> PKCanvasView {
        canvas.tool = PKInkingTool(.pen, color: UIColor(Theme.accent), width: 4)
        canvas.drawingPolicy = .anyInput
        if let data, let drawing = try? PKDrawing(data: data) {
            canvas.drawing = drawing
        }
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}
}

struct DocumentScannerView: UIViewControllerRepresentable {
    var onScan: ([UIImage]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan, dismiss: dismiss) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onScan: ([UIImage]) -> Void
        let dismiss: DismissAction
        init(onScan: @escaping ([UIImage]) -> Void, dismiss: DismissAction) {
            self.onScan = onScan
            self.dismiss = dismiss
        }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            var images: [UIImage] = []
            for index in 0..<scan.pageCount { images.append(scan.imageOfPage(at: index)) }
            onScan(images)
            dismiss()
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { dismiss() }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { dismiss() }
    }
}
