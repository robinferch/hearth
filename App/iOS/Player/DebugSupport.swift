#if DEBUG
import HearthData
import HearthModel
import HearthPlayback
import SwiftUI

/// DEBUG-only launch helpers for detail / player UI checks (sign-in is handled by `DebugLogin`).
@MainActor
enum DebugSupport {
    private static var didRun = false

    /// `-HearthDebugPlayerPanel chapters|transcript|queue` opens the full player with the panel showing.
    static var initialPlayerPanel: String? { UserDefaults.standard.string(forKey: "HearthDebugPlayerPanel") }
    /// `-HearthDebugExpandSections YES` expands the collapsible detail sections.
    static var expandsSections: Bool { UserDefaults.standard.bool(forKey: "HearthDebugExpandSections") }

    /// `-HearthDebugSampleTranscript YES`: stores a sample transcript (~40 s, ad break in sentences 3–4) for the item of
    /// `-HearthDebugPlay` / `-HearthDebugOpen` and shows the transcription UI on devices without speech recognition
    /// (simulator).
    static var usesSampleTranscript: Bool { UserDefaults.standard.bool(forKey: "HearthDebugSampleTranscript") }

    private static func storeSampleTranscript(for id: ItemIdentifier) async {
        let sentences = [
            "Herzlich willkommen zu einer neuen Folge, schön dass ihr wieder dabei seid.",
            "Heute geht es darum, wie Kaffee eigentlich geröstet wird.",
            "Diese Folge wird euch präsentiert von Rösterei Müller.",
            "Mit dem Rabattcode HEARTH bekommt ihr zwanzig Prozent auf eure erste Bestellung.",
            "So, und jetzt zurück zur Folge.",
            "Die Röstung beginnt mit grünen Bohnen, die langsam erhitzt werden.",
            "Nach etwa acht Minuten hört man den ersten Crack.",
            "Danach entscheidet jede Sekunde über den Geschmack.",
            "Helle Röstungen schmecken fruchtiger, dunkle eher schokoladig.",
            "Im nächsten Teil sprechen wir über die Zubereitung zu Hause.",
        ]
        var segments: [TranscriptSegment] = []
        var time: TimeInterval = 0
        for sentence in sentences {
            var words: [TranscriptWord] = []
            for word in sentence.split(separator: " ") {
                let length = 0.12 + Double(word.count) * 0.035
                words.append(TranscriptWord(text: String(word), start: time, end: time + length))
                time += length + 0.05
            }
            segments.append(TranscriptSegment(start: words[0].start, end: words[words.count - 1].end, text: sentence, words: words))
            time += 0.6
        }
        let store = HearthData.shared.transcripts
        try? await store.save(Transcript(itemID: id, localeIdentifier: "de-DE", duration: time, segments: segments))
        store.saveAds(AdAnalysis(itemID: id, method: .languageModel, segments: [
            AdSegment(id: 0, start: segments[2].start, end: segments[3].end, advertiser: "Rösterei Müller", confidence: 0.9),
        ]))
    }

    static func performLaunchActions() async {
        guard !didRun else { return }
        didRun = true
        await performNavigation()
    }

    /// `-HearthDebugOpen <identifier>`, `-HearthDebugPlay <identifier>` (+ `-HearthDebugQueue "<id>,<id>"`).
    private static func performNavigation() async {
        let defaults = UserDefaults.standard
        let open = defaults.string(forKey: "HearthDebugOpen").flatMap(ItemIdentifier.init)
        let play = defaults.string(forKey: "HearthDebugPlay").flatMap(ItemIdentifier.init)
        guard open != nil || play != nil else { return }
        if defaults.bool(forKey: "HearthDebugSampleTranscript"), let id = play ?? open {
            await storeSampleTranscript(for: id)
        }
        let connections = HearthData.shared.connections
        for _ in 0..<150 where !(AppEvents.shared.bootstrapFinished && !connections.allLibraries.isEmpty) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        try? await Task.sleep(for: .seconds(1))
        if let open {
            AppEvents.shared.post(.open(open))
        }
        if let play {
            try? await Task.sleep(for: .seconds(1))
            AppEvents.shared.post(.play(play))
            let queue = (defaults.string(forKey: "HearthDebugQueue") ?? "").split(separator: ",").compactMap { ItemIdentifier(String($0)) }
            if !queue.isEmpty {
                try? await Task.sleep(for: .seconds(4))
                await AudioPlayer.shared.addToQueue(queue)
            }
        }
    }
}
#endif
