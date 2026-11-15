import AVFoundation

/// 朗读英文（系统语音，不联网）
@MainActor
enum Speech {
    private static let synthesizer = AVSpeechSynthesizer()

    static func speak(_ text: String, slow: Bool = false) {
        // 默认的音频类别在静音模式下不出声；朗读按播放类处理，同时压低其他 App 的声音
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        synthesizer.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        u.rate = slow ? AVSpeechUtteranceDefaultSpeechRate * 0.8 : AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(u)
    }
}
