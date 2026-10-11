#if DEBUG
import HearthData
import HearthModel
import HearthPlayback
import SwiftUI

/// DEBUG-only launch helpers for detail / player UI checks (sign-in is handled by `DebugLogin`).
@MainActor
enum DebugSupport {
    private static var didRun = false

    /// `-HearthDebugPlayerPanel chapters|queue` opens the full player with the panel showing.
    static var initialPlayerPanel: String? { UserDefaults.standard.string(forKey: "HearthDebugPlayerPanel") }
    /// `-HearthDebugExpandSections YES` expands the collapsible detail sections.
    static var expandsSections: Bool { UserDefaults.standard.bool(forKey: "HearthDebugExpandSections") }

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
