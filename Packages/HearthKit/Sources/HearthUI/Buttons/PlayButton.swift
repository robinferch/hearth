import HearthData
import HearthModel
import SwiftUI

/// Play / resume button with progress fill.
///
/// - `.large`: full-width glass pill for detail headers ("Resume • 3h 12m left"), tinted with the
///   cover's dominant color when provided.
/// - `.medium`: compact glass pill.
/// - `.inline`: small episode pill with an inline progress bar ("Play again" / remaining / duration).
public struct PlayButton: View {
    public enum Style: Sendable {
        case large
        case medium
        case inline
    }

    let item: AnyPlayableItem
    let style: Style
    let tint: HearthRGBColor?

    @Environment(\.itemActionHandler) private var handler
    @Environment(\.isEnabled) private var isEnabled

    public init(item: AnyPlayableItem, style: Style = .large, tint: HearthRGBColor? = nil) {
        self.item = item
        self.style = style
        self.tint = tint
    }

    public var body: some View {
        let status = ItemStatus.of(item.id)
        let playing = handler.isPlaying(item.id)
        let title = title(status: status, playing: playing)
        let detail = detail(status: status)

        Button {
            Task { await handler.play(item.id) }
        } label: {
            switch style {
            case .large, .medium:
                pillLabel(title: title, detail: detail, status: status, playing: playing)
            case .inline:
                inlineLabel(title: title, detail: detail, status: status, playing: playing)
            }
        }
        .buttonStyle(.plain)
        .disabled(!handler.canPlay)
        .sensoryFeedback(.impact(weight: .light), trigger: playing)
        .accessibilityLabel(playing ? loc("Pause") : title)
        .accessibilityValue(detail ?? "")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(style == .inline ? "playButton.inline" : "playButton")
    }

    // MARK: Pill

    private func pillLabel(title: String, detail: String?, status: ItemStatus, playing: Bool) -> some View {
        let large = style == .large
        let fill = tint?.color ?? .hearthTint
        let foreground: Color = tint.map { $0.isLight ? .black : .white } ?? .white

        return HStack(spacing: 8) {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .contentTransition(.symbolEffect(.replace))
            Text(title)
                .fontWeight(.semibold)
            if let detail {
                Text(verbatim: "•")
                    .foregroundStyle(foreground.opacity(0.6))
                Text(detail)
                    .foregroundStyle(foreground.opacity(0.85))
            }
        }
        .font(large ? .body : .subheadline)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .foregroundStyle(foreground)
        .padding(.horizontal, large ? 22 : 14)
        .padding(.vertical, large ? 14 : 8)
        .frame(maxWidth: large ? .infinity : nil)
        .background {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(fill.opacity(0.78))
                    if status.isInProgress {
                        Rectangle()
                            .fill(fill)
                            .frame(width: proxy.size.width * status.fraction)
                    }
                }
            }
        }
        .clipShape(.capsule)
        .glassEffect(.regular.tint(fill.opacity(0.35)).interactive(), in: .capsule)
        .contentShape(.capsule)
        .opacity(isEnabled ? 1 : 0.6)
    }

    // MARK: Inline

    private func inlineLabel(title: String, detail: String?, status: ItemStatus, playing: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.caption2)
                .contentTransition(.symbolEffect(.replace))
            if status.isInProgress {
                ProgressCapsule(progress: status.fraction, height: 3, tint: .primary)
                    .frame(width: 28)
            }
            Text(status.isInProgress || status.isFinished ? title : (detail ?? title))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(.tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.tint.opacity(0.14), in: .capsule)
        .contentShape(.capsule)
        .opacity(isEnabled ? 1 : 0.6)
    }

    // MARK: Text

    private func title(status: ItemStatus, playing: Bool) -> String {
        let isBook = item.id.kind == .audiobook
        if style == .inline {
            if status.isFinished { return loc("Play again") }
            if status.isInProgress {
                return HearthFormat.remaining(status.remaining(duration: item.duration), rate: ItemStatus.effectiveRate(for: item.id))
            }
            return loc("Play")
        }
        if playing { return loc("Pause") }
        if status.isFinished { return isBook ? loc("Listen again") : loc("Play again") }
        if status.isInProgress { return loc("Resume") }
        return isBook ? loc("Listen") : loc("Play")
    }

    private func detail(status: ItemStatus) -> String? {
        let rate = ItemStatus.effectiveRate(for: item.id)
        if status.isInProgress {
            let value = HearthFormat.remaining(status.remaining(duration: item.duration), rate: rate)
            return value.isEmpty ? nil : value
        }
        let value = HearthFormat.duration(item.duration, rate: rate)
        return value.isEmpty ? nil : value
    }
}

#if DEBUG
#Preview("Play buttons") {
    VStack(spacing: 20) {
        PlayButton(item: .audiobook(PreviewFixtures.audiobook))
        PlayButton(item: .audiobook(PreviewFixtures.audiobook), tint: HearthRGBColor(red: 0.2, green: 0.3, blue: 0.5))
        PlayButton(item: .episode(PreviewFixtures.episode), style: .medium)
        PlayButton(item: .episode(PreviewFixtures.episode), style: .inline)
    }
    .padding()
    .tint(TintColor.hearth.color)
}
#endif
