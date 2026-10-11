import AVFoundation
import AVKit
import HearthModel
import HearthPlayback
import HearthUI
import MediaPlayer
import SwiftUI
import UIKit

// MARK: - Volume

/// Observes the system output volume and changes it through a (hidden) `MPVolumeView`.
@MainActor
@Observable
final class SystemVolume {
    private(set) var volume: Float = AVAudioSession.sharedInstance().outputVolume

    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored weak var slider: UISlider?

    init() {
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in
                self?.volume = value
            }
        }
    }

    func set(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        volume = clamped
        guard let slider else { return }
        slider.value = clamped
        slider.sendActions(for: .valueChanged)
    }
}

/// Hidden `MPVolumeView` that suppresses the system volume HUD and provides the slider used to set the volume.
private struct HiddenVolumeView: UIViewRepresentable {
    let volume: SystemVolume

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 100, height: 20))
        view.alpha = 0.0001
        view.isUserInteractionEnabled = false
        volume.slider = view.subviews.compactMap { $0 as? UISlider }.first
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        if volume.slider == nil {
            volume.slider = view.subviews.compactMap { $0 as? UISlider }.first
        }
    }
}

/// System volume slider (speaker icons on both ends), backed by `MPVolumeView`.
struct VolumeSlider: View {
    @State private var volume = SystemVolume()
    @State private var dragValue: Float?
    @State private var dragStart: Float = 0

    private var shown: Float { dragValue ?? volume.volume }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.2))
                    Capsule()
                        .fill(.primary.opacity(dragValue == nil ? 0.75 : 1))
                        .frame(width: width * CGFloat(shown))
                }
                .frame(height: dragValue == nil ? 6 : 10)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            // Relative movement from the touch point (no jump on touch down).
                            if dragValue == nil {
                                dragStart = volume.volume
                            }
                            let value = min(max(dragStart + Float(gesture.translation.width / width), 0), 1)
                            dragValue = value
                            volume.set(value)
                        }
                        .onEnded { _ in
                            dragValue = nil
                        }
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: dragValue == nil)
            }
            .frame(height: 24)
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .background {
            HiddenVolumeView(volume: volume)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Volume", table: "Player"))
        .accessibilityValue(HearthFormat.percent(Double(volume.volume)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: volume.set(volume.volume + 0.0625)
            case .decrement: volume.set(volume.volume - 0.0625)
            @unknown default: break
            }
        }
    }
}

// MARK: - AirPlay

/// AirPlay route picker showing the current route's icon.
struct RoutePickerButton: View {
    let route: AudioRoute

    var body: some View {
        ZStack {
            Image(systemName: route.systemImage)
                .font(.title3)
                .foregroundStyle(route.isExternal ? AnyShapeStyle(Color.hearthTint) : AnyShapeStyle(.primary))
                .contentTransition(.symbolEffect(.replace))
            RoutePickerRepresentable()
                .frame(width: 44, height: 44)
        }
        .frame(width: 44, height: 44)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "AirPlay", table: "Player"))
        .accessibilityValue(route.name)
    }
}

private struct RoutePickerRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        // The SwiftUI icon above shows the route; keep the picker's own glyph invisible but tappable.
        view.tintColor = .clear
        view.activeTintColor = .clear
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
