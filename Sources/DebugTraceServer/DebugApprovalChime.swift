import Foundation
#if canImport(AudioToolbox)
import AudioToolbox
#endif

/// The sound that says "someone is asking to debug this app". The prompt is
/// easy to miss: it appears on a headset or a device across the room, and the
/// request behind it only waits `approvalTimeout`.
///
/// Synthesized rather than a system sound id or a bundled file: ids differ
/// between platforms and OS releases, and a package that ships no resources
/// has nothing to forget to copy. A descending three-note mallet tone, kept clear of any
/// well-known device or console jingle.
///
/// It is played as a system alert sound (`AudioServices`), not through
/// `AVAudioPlayer`: an audio player activates the app's audio session, which
/// pauses whatever the person is listening to in another app (music stopped
/// on a Vision Pro under the player). An alert sound mixes with other audio
/// by design, and never touches the app's own session.
@MainActor
enum DebugApprovalChime {
    /// How long a prompt sits unanswered before it chimes again.
    nonisolated static let repeatInterval: Duration = .seconds(8)

    #if canImport(AudioToolbox)
    private static var soundID: SystemSoundID?
    #endif

    static func play() {
        #if canImport(AudioToolbox)
        if soundID == nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("debugtrace-approval-chime.wav")
            guard (try? wav.write(to: url, options: .atomic)) != nil else { return }
            var id: SystemSoundID = 0
            guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError else { return }
            soundID = id
        }
        if let soundID { AudioServicesPlayAlertSound(soundID) }
        #endif
    }

    /// Chimes now and every `repeatInterval` until the returned task is cancelled.
    static func start() -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                play()
                try? await Task.sleep(for: repeatInterval)
            }
        }
    }

    /// 16-bit mono PCM: a descending triplet (A5, F5, D5) in a struck-bar timbre:
    /// inharmonic upper partials that die away faster than the fundamental,
    /// with a short attack and a long ring on the last note.
    nonisolated static let wav: Data = {
        let rate = 44_100
        let notes: [(frequency: Double, seconds: Double)] = [(880.00, 0.15), (698.46, 0.15), (587.33, 0.55)]
        var samples: [Int16] = []
        for note in notes {
            let count = Int(Double(rate) * note.seconds)
            for i in 0..<count {
                let t = Double(i) / Double(rate)
                let attack = min(1, t / 0.004)
                let body = exp(-4 * t / note.seconds)
                let bright = exp(-14 * t / note.seconds)
                let tone = sin(2 * .pi * note.frequency * t)
                    + 0.5 * bright * sin(2 * .pi * note.frequency * 2.76 * t)
                    + 0.25 * bright * sin(2 * .pi * note.frequency * 5.4 * t)
                samples.append(Int16(max(-1, min(1, 0.5 * attack * body * tone)) * Double(Int16.max)))
            }
        }
        func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] { withUnsafeBytes(of: value.littleEndian) { Array($0) } }
        let dataBytes = samples.count * 2
        var out = Data()
        out += Array("RIFF".utf8) + le(UInt32(36 + dataBytes)) + Array("WAVEfmt ".utf8)
        out += le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1)) + le(UInt32(rate)) + le(UInt32(rate * 2)) + le(UInt16(2)) + le(UInt16(16))
        out += Array("data".utf8) + le(UInt32(dataBytes))
        for sample in samples { out += le(sample) }
        return out
    }()
}
