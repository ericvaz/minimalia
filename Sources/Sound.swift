import AVFoundation

/// The start-up chime. It is the only sound Minimalia makes, and CHIME OFF silences it.
@MainActor
enum Sound {
    private static var player: AVAudioPlayer?

    static func chime() {
        guard Settings.shared.chime, let url = Bundle.main.url(forResource: "Chime", withExtension: "mp3") else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.volume = 0.6
        player?.play()
    }
}
