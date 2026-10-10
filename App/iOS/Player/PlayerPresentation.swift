import Foundation
import HearthPlayback
import Observation
import SwiftUI

/// Controls the full-screen player presentation for a scene.
///
/// The mini player (`MiniPlayerView`, shown as `tabViewBottomAccessory`) sets `isExpanded = true`
/// on tap; `MainTabView` presents `NowPlayingView` as a full-screen cover with a zoom transition
/// from `PlayerPresentation.transitionSourceID` in the namespace `\.playerNamespace`.
@MainActor
@Observable
final class PlayerPresentation {
    /// Matched-transition source id used by the mini player and the full player.
    static let transitionSourceID = "now-playing"

    var isExpanded = false

    /// When playback was explicitly stopped (to suppress auto-open shortly after).
    var stoppedAt: Date?

    func expand() {
        isExpanded = true
    }

    func collapse() {
        isExpanded = false
    }

    /// Called when a new item started from the UI: auto-opens the player unless it was stopped < 10 s ago.
    func itemStarted() {
        if let stoppedAt, Date.now.timeIntervalSince(stoppedAt) < 10 {
            return
        }
        isExpanded = true
    }
}

extension EnvironmentValues {
    /// Namespace for the mini player → full player zoom transition.
    @Entry var playerNamespace: Namespace.ID?
}
