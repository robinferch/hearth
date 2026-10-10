import HearthData
import HearthModel
import SwiftUI

/// Circular progress ring.
public struct ProgressRing: View {
    let progress: Double
    let lineWidth: CGFloat
    let tint: Color?

    public init(progress: Double, lineWidth: CGFloat = 3, tint: Color? = nil) {
        self.progress = progress
        self.lineWidth = lineWidth
        self.tint = tint
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(.secondary.opacity(0.3), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.smooth, value: progress)
        .accessibilityElement()
        .accessibilityLabel(loc("Progress"))
        .accessibilityValue(HearthFormat.percent(progress))
    }
}

/// Thin linear capsule progress bar.
public struct ProgressCapsule: View {
    let progress: Double
    let height: CGFloat
    let tint: Color?

    public init(progress: Double, height: CGFloat = 4, tint: Color? = nil) {
        self.progress = progress
        self.height = height
        self.tint = tint
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.25))
                Capsule()
                    .fill(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint))
                    .frame(width: max(height, proxy.size.width * min(max(progress, 0), 1)))
                    .opacity(progress > 0 ? 1 : 0)
            }
        }
        .frame(height: height)
        .animation(.smooth, value: progress)
        .accessibilityElement()
        .accessibilityLabel(loc("Progress"))
        .accessibilityValue(HearthFormat.percent(progress))
    }
}

/// ¾ gauge showing minutes listened today against the daily goal.
public struct ListenedTodayGauge: View {
    let listened: TimeInterval
    let goalMinutes: Int
    let lineWidth: CGFloat
    let showsLabel: Bool

    public init(listened: TimeInterval, goalMinutes: Int, lineWidth: CGFloat = 3.5, showsLabel: Bool = true) {
        self.listened = listened
        self.goalMinutes = goalMinutes
        self.lineWidth = lineWidth
        self.showsLabel = showsLabel
    }

    private var minutes: Int { Int(listened / 60) }
    private var fraction: Double {
        guard goalMinutes > 0 else { return 0 }
        return min(Double(minutes) / Double(goalMinutes), 1)
    }

    public var body: some View {
        ZStack {
            arc(to: 1)
                .stroke(.secondary.opacity(0.3), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            arc(to: fraction)
                .stroke(.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            if showsLabel {
                Text(minutes, format: .number)
                    .font(.system(size: 100, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.05)
                    .lineLimit(1)
                    .monospacedDigit()
                    .padding(lineWidth * 2.2)
                    .contentTransition(.numericText(value: Double(minutes)))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .animation(.smooth, value: fraction)
        .accessibilityElement()
        .accessibilityLabel(loc("Listened today"))
        .accessibilityValue(String(localized: "\(minutes) of \(goalMinutes) minutes", bundle: .module))
    }

    private func arc(to value: Double) -> some Shape {
        Circle()
            .trim(from: 0, to: 0.75 * value)
            .rotation(.degrees(135))
    }
}

/// Download progress ring with a stop glyph (tap cancels where used as a button).
public struct DownloadProgressRing: View {
    let progress: Double
    let lineWidth: CGFloat

    public init(progress: Double, lineWidth: CGFloat = 2.5) {
        self.progress = progress
        self.lineWidth = lineWidth
    }

    public var body: some View {
        ZStack {
            ProgressRing(progress: progress, lineWidth: lineWidth)
            if progress <= 0 {
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .phaseAnimator([0.0, 360.0]) { view, angle in
                        view.rotationEffect(.degrees(angle))
                    } animation: { _ in .linear(duration: 1).repeatForever(autoreverses: false) }
            }
            RoundedRectangle(cornerRadius: 1.5)
                .fill(.tint)
                .scaleEffect(0.32)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(loc("Downloading"))
        .accessibilityValue(HearthFormat.percent(progress))
    }
}

/// Compact trailing indicator for rows: download ring, progress ring, checkmark or downloaded arrow.
public struct ItemStatusIndicator: View {
    let id: ItemIdentifier

    public init(id: ItemIdentifier) {
        self.id = id
    }

    public var body: some View {
        let status = ItemStatus.of(id)
        Group {
            if status.isDownloading {
                DownloadProgressRing(progress: status.downloadProgress)
            } else if status.isFinished {
                Image(systemName: "checkmark.circle.fill")
                    .resizable()
                    .foregroundStyle(.tint)
            } else if status.isInProgress {
                ProgressRing(progress: status.fraction, lineWidth: 2.5)
            } else if status.isDownloaded {
                Image(systemName: "arrow.down.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

/// Corner triangle on grid covers: progress ring (or %), finished checkmark, download progress or downloaded arrow.
public struct CoverStatusOverlay: View {
    let id: ItemIdentifier

    public init(id: ItemIdentifier) {
        self.id = id
    }

    public var body: some View {
        let status = ItemStatus.of(id)
        let showPercent = AppSettings.shared.showProgressPercent
        if status.isDownloading || status.isFinished || status.isInProgress || status.isDownloaded {
            GeometryReader { proxy in
                let side = min(max(proxy.size.width * 0.36, 26), 54)
                let glyph = side * 0.36
                ZStack(alignment: .bottomTrailing) {
                    CornerTriangle()
                        .fill(.ultraThinMaterial)
                        .overlay(CornerTriangle().fill(.black.opacity(0.12)))
                        .frame(width: side, height: side)
                    Group {
                        if status.isDownloading {
                            DownloadProgressRing(progress: status.downloadProgress, lineWidth: 2)
                        } else if status.isFinished {
                            Image(systemName: "checkmark")
                                .resizable()
                                .scaledToFit()
                                .fontWeight(.bold)
                                .foregroundStyle(.tint)
                        } else if status.isInProgress {
                            if showPercent {
                                Text(verbatim: "\(Int(status.fraction * 100))")
                                    .font(.system(size: glyph * 0.75, weight: .bold, design: .rounded))
                                    .minimumScaleFactor(0.5)
                                    .foregroundStyle(.primary)
                            } else {
                                ProgressRing(progress: status.fraction, lineWidth: max(2, glyph * 0.18))
                            }
                        } else {
                            Image(systemName: "arrow.down")
                                .resizable()
                                .scaledToFit()
                                .fontWeight(.bold)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: glyph, height: glyph)
                    .padding(side * 0.1)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomTrailing)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// Right triangle filling the bottom-trailing corner.
public struct CornerTriangle: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

#if DEBUG
#Preview("Progress") {
    VStack(spacing: 24) {
        ProgressRing(progress: 0.42).frame(width: 40, height: 40)
        ProgressCapsule(progress: 0.66).frame(width: 200)
        ListenedTodayGauge(listened: 17 * 60, goalMinutes: 30).frame(width: 44)
        DownloadProgressRing(progress: 0.3).frame(width: 24)
    }
    .tint(TintColor.hearth.color)
    .padding()
}
#endif
