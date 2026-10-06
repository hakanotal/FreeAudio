import AppKit
import AVFoundation

// Tone player for spike S5: plays the WAV file given as the first argument in a loop until quit.
// Built twice with different bundle IDs (ToneA, ToneB) to stand in for two separate apps.
let player: AVAudioPlayer? = CommandLine.arguments.count > 1
    ? try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    : nil
player?.numberOfLoops = -1
player?.play()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
