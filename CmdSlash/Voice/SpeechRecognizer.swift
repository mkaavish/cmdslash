import AVFoundation
import Speech

/// Streams microphone audio into on-device speech recognition where available
/// (Docs/PLANNING.md §17) — chosen over a cloud STT API to avoid adding network latency to the
/// activation path and to keep audio local by default.
@MainActor
final class SpeechRecognizer {
    enum RecognizerError: Error, LocalizedError {
        case notAuthorized
        case recognizerUnavailable
        case audioEngineFailure(Error)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                "Microphone or speech recognition access wasn't granted."
            case .recognizerUnavailable:
                "Speech recognition isn't available right now."
            case .audioEngineFailure(let error):
                "Audio capture failed: \(error.localizedDescription)"
            }
        }
    }

    var onPartialTranscript: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    static func requestAuthorization() async -> Bool {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else { return false }

        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    var isListening: Bool { audioEngine.isRunning }

    func startListening() throws {
        guard let recognizer, recognizer.isAvailable else {
            throw RecognizerError.recognizerUnavailable
        }
        stopListening()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            throw RecognizerError.audioEngineFailure(error)
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.onPartialTranscript?(result.bestTranscription.formattedString)
                }
                if let error {
                    self.onError?(error)
                }
            }
        }
    }

    func stopListening() {
        guard audioEngine.isRunning || request != nil else { return }
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
    }
}
