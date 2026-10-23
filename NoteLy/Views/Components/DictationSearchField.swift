import AVFoundation
import Speech
import SwiftUI

/// English-only voice search. Other languages are not requested.
@MainActor
final class EnglishDictation: ObservableObject {
    @Published var isListening = false
    @Published var notice: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var base = ""
    private var tapInstalled = false
    private var stopping = false

    func toggle(text: Binding<String>) {
        if isListening {
            stop()
        } else {
            start(text: text)
        }
    }

    func stop() {
        guard !stopping else { return }
        stopping = true
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        stopping = false
    }

    private func start(text: Binding<String>) {
        guard let recognizer, recognizer.isAvailable else {
            notice = "Voice search works in English."
            return
        }
        AVAudioApplication.requestRecordPermission { allowed in
            Task { @MainActor in
                guard allowed else {
                    self.notice = "The microphone is turned off for NoteLy."
                    return
                }
                SFSpeechRecognizer.requestAuthorization { status in
                    Task { @MainActor in
                        guard status == .authorized else {
                            self.notice = "Speech recognition is turned off for NoteLy."
                            return
                        }
                        self.begin(text: text, recognizer: recognizer)
                    }
                }
            }
        }
    }

    private func begin(text: Binding<String>, recognizer: SFSpeechRecognizer) {
        stop()
        base = text.wrappedValue
        notice = nil
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = false
        self.request = request
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let node = engine.inputNode
            let format = node.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                notice = "Voice search works in English."
                stop()
                return
            }
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            isListening = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, !self.stopping else { return }
                    if let result {
                        let spoken = result.bestTranscription.formattedString
                        let prefix = self.base.trimmingCharacters(in: .whitespacesAndNewlines)
                        text.wrappedValue = prefix.isEmpty ? spoken : prefix + " " + spoken
                    }
                    if error != nil || result?.isFinal == true {
                        self.stop()
                    }
                }
            }
        } catch {
            notice = "Voice search works in English."
            stop()
        }
    }
}

/// Search capsule with a microphone inside, a clear button, and the blue dictation bubble.
struct DictationSearchField: View {
    @Binding var text: String
    var prompt: String
    var onSubmit: () -> Void = {}
    @StateObject private var voice = EnglishDictation()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                field
                if focused {
                    Button {
                        voice.stop()
                        focused = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .notesGlass(in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close keyboard")
                }
            }
            .padding(.top, voice.isListening ? 18 : 0)
            .overlay(alignment: .topLeading) {
                if voice.isListening {
                    Button {
                        voice.stop()
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.blue, in: Circle())
                            .shadow(color: Color.blue.opacity(0.35), radius: 8, y: 2)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 46, y: -8)
                    .accessibilityLabel("Stop voice search")
                }
            }
            if let notice = voice.notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
            TextField(prompt, text: $text)
                .focused($focused)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit {
                    voice.stop()
                    onSubmit()
                }
            if !text.isEmpty {
                Button {
                    voice.stop()
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
            Button {
                voice.toggle(text: $text)
            } label: {
                Image(systemName: voice.isListening ? "mic.fill" : "mic")
                    .font(.system(size: 17))
                    .foregroundStyle(voice.isListening ? Color.blue : Color.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(voice.isListening ? "Stop voice search" : "Voice search")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color(.systemBackground), in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}
