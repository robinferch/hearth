import SwiftUI

/// Thin playback position bar that grows while dragging.
///
/// Dragging is accelerated by the finger's velocity (< 600 pt/s → 1×, < 1000 → 2×, else 3×) and a release
/// fling adds 10 % of the predicted remaining movement. While dragging, `onScrub` reports the preview position
/// so labels can follow; `onCommit` delivers the final position.
public struct PlaybackScrubber: View {
    let value: TimeInterval
    let total: TimeInterval
    let isLocked: Bool
    let tint: Color
    let onScrub: (TimeInterval?) -> Void
    let onCommit: (TimeInterval) -> Void

    @State private var dragValue: TimeInterval?
    @State private var lastTranslation: CGFloat = 0
    @State private var lastSampleDate = Date.distantPast
    @GestureState private var isPressing = false

    public init(value: TimeInterval, total: TimeInterval, isLocked: Bool = false, tint: Color = .primary, onScrub: @escaping (TimeInterval?) -> Void = { _ in }, onCommit: @escaping (TimeInterval) -> Void) {
        self.value = value
        self.total = total
        self.isLocked = isLocked
        self.tint = tint
        self.onScrub = onScrub
        self.onCommit = onCommit
    }

    private var isDragging: Bool { dragValue != nil }
    private var displayed: TimeInterval { dragValue ?? value }
    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(max(displayed / total, 0), 1)
    }

    /// Velocity → multiplier (spec §6).
    static func multiplier(forVelocity velocity: CGFloat) -> CGFloat {
        let speed = abs(velocity)
        if speed < 600 { return 1 }
        if speed < 1000 { return 2 }
        return 3
    }

    public var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let height: CGFloat = isDragging ? 14 : 7
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(tint.opacity(0.22))
                Capsule()
                    .fill(tint.opacity(isDragging ? 1 : 0.85))
                    .frame(width: max(height, width * fraction))
                    .opacity(fraction > 0 ? 1 : 0)
            }
            .frame(height: height)
            .clipShape(.capsule)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(dragGesture(width: width), including: isLocked || total <= 0 ? .subviews : .all)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isDragging)
        }
        .frame(height: 28)
        .sensoryFeedback(.selection, trigger: isDragging)
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Playback position", table: "Player", bundle: .module))
        .accessibilityValue(String(localized: "\(value.clockFormattedForAccessibility) of \(total.clockFormattedForAccessibility)", table: "Player", bundle: .module))
        .accessibilityAdjustableAction { direction in
            guard !isLocked, total > 0 else { return }
            let step = max(15, total / 50)
            switch direction {
            case .increment: onCommit(min(total, value + step))
            case .decrement: onCommit(max(0, value - step))
            @unknown default: break
            }
        }
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                let start = dragValue ?? value
                if dragValue == nil {
                    lastTranslation = 0
                    lastSampleDate = .now
                }
                let delta = gesture.translation.width - lastTranslation
                let elapsed = max(Date.now.timeIntervalSince(lastSampleDate), 1 / 120)
                let velocity = delta / elapsed
                lastTranslation = gesture.translation.width
                lastSampleDate = .now
                let seconds = Double(delta / width * Self.multiplier(forVelocity: velocity)) * total
                let next = min(max(start + seconds, 0), total)
                dragValue = next
                onScrub(next)
            }
            .onEnded { gesture in
                guard let current = dragValue else { return }
                let fling = (gesture.predictedEndTranslation.width - gesture.translation.width) * 0.1
                let final = min(max(current + Double(fling / width) * total, 0), total)
                dragValue = nil
                onScrub(nil)
                onCommit(final)
            }
    }
}

private extension TimeInterval {
    /// Spoken style "1 hour, 2 minutes, 3 seconds".
    var clockFormattedForAccessibility: String {
        guard isFinite, self >= 0 else { return "" }
        return Duration.seconds(self.rounded(.down)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}

#if DEBUG
#Preview("Scrubber") {
    PlaybackScrubber(value: 120, total: 600) { _ in }
        .padding()
}
#endif
