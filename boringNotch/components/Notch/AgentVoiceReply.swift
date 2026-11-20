import AppKit
import AVFoundation
import Carbon
import Speech
import SwiftUI

enum AgentVoiceEngine: String, CaseIterable, Identifiable {
    case onDevice, doubao
    static let preferenceKey = "agentVoiceReplyEngine"
    var id: String { rawValue }
}

struct AgentVoiceFocus: Equatable {
    let sessionID: UUID
    let id = UUID()
}

/// One draft-scoped recognition session. Audio is passed only to Apple's
/// on-device recognizer. The caller keeps ownership of the draft and send action.
@MainActor
final class AgentVoiceReply: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var status: LocalizedStringKey?

    private lazy var audio = AVAudioEngine()
    private var hasTap = false
    var hasStartedRecording: Bool { request != nil }
    private var runID: UUID?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var finishTimeout: Task<Void, Never>?
    private var originalSource: TISInputSource?

    func toggle(engine: AgentVoiceEngine, update: @escaping (String) -> Bool) {
        if isActive {
            finish()
            return
        }
        if engine == .doubao {
            prepareDoubao()
            return
        }

        let id = UUID()
        runID = id
        isActive = true
        status = "正在准备听写…"
        Task { [weak self] in
            guard let self else { return }
            let microphone = await AVCaptureDevice.requestAccess(for: .audio)
            guard self.runID == id else { return }
            guard microphone else {
                self.cancel()
                self.status = "请在系统设置中允许 Notch Harbor 使用麦克风"
                return
            }
            let authorized = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
            guard self.runID == id else { return }
            guard authorized else {
                self.cancel()
                self.status = "请在系统设置中允许语音识别"
                return
            }
            self.start(id: id, update: update)
        }
    }

    private func start(id: UUID, update: @escaping (String) -> Bool) {
        let locale = Locale.autoupdatingCurrent
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            cancel()
            status = "当前系统语言的本机听写不可用，可在设置中改用豆包"
            return
        }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.request = request
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            cancel()
            status = "没有可用的麦克风"
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        hasTap = true
        do {
            try audio.start()
        } catch {
            cancel()
            status = "无法启动麦克风"
            return
        }
        status = "正在听写，再按一次快捷键结束"
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            let failed = error != nil
            Task { @MainActor [weak self] in
                guard let self, self.runID == id else { return }
                if let text, !update(text) {
                    self.cancel()
                } else if final || failed {
                    let wasFinishing = self.finishTimeout != nil
                    self.cancel()
                    self.status = failed && !wasFinishing ? "听写已中断，已转写的文字留在草稿中" : nil
                }
            }
        }
    }

    private func stopAudio() {
        guard hasTap else { return }
        if audio.isRunning { audio.stop() }
        audio.inputNode.removeTap(onBus: 0)
        hasTap = false
    }

    private func finish() {
        guard let request else { cancel(); return }
        guard finishTimeout == nil else { return }
        stopAudio()
        request.endAudio()
        status = "正在完成转写…"
        finishTimeout = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            if !Task.isCancelled { self?.cancel() }
        }
    }

    func cancel() {
        runID = nil
        stopAudio()
        if finishTimeout == nil { request?.endAudio() }
        recognition?.cancel()
        finishTimeout?.cancel()
        request = nil
        recognition = nil
        recognizer = nil
        finishTimeout = nil
        isActive = false
        status = nil
        if let originalSource {
            if Self.isDoubao(TISCopyCurrentKeyboardInputSource().takeRetainedValue()) {
                TISSelectInputSource(originalSource)
            }
            self.originalSource = nil
        }
    }

    private func prepareDoubao() {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        if !Self.isDoubao(current) {
            let list = TISCreateInputSourceList(nil, false).takeRetainedValue()
            let switched = (0..<CFArrayGetCount(list)).contains { index in
                guard let value = CFArrayGetValueAtIndex(list, index) else { return false }
                let candidate = Unmanaged<TISInputSource>.fromOpaque(value).takeUnretainedValue()
                return Self.isDoubao(candidate) && TISSelectInputSource(candidate) == noErr
            }
            guard switched else {
                status = "请先在系统键盘设置中添加豆包输入法"
                return
            }
            originalSource = current
        }
        status = "按住 Fn 或豆包设置的语音键开始说话"
    }

    private static func isDoubao(_ source: TISInputSource) -> Bool {
        guard let value = TISGetInputSourceProperty(source, kTISPropertyBundleID) else { return false }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String == "com.bytedance.inputmethod.doubaoime"
    }
}
