import Foundation
import HearthModel

/// Platform independent mirror of the `AVAudioSession.Port` values we care about.
enum AudioOutputPort: Sendable, Hashable {
    case builtInSpeaker
    case builtInReceiver
    case headphones
    case bluetoothA2DP
    case bluetoothLE
    case bluetoothHFP
    case airPlay
    case carAudio
    case hdmi
    case usb
    case lineOut
    case other
}

/// Maps an output port + its name onto the icon kind shown on the route button.
enum AudioRouteClassifier {
    static func kind(port: AudioOutputPort, name: String) -> AudioRoute.Kind {
        let lowered = name.lowercased()
        switch port {
        case .builtInSpeaker, .builtInReceiver, .other:
            return .speaker
        case .headphones:
            return .headphones
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
            if lowered.contains("airpods max") {
                return .airPodsMax
            }
            if lowered.contains("airpods pro") {
                return .airPodsPro
            }
            if lowered.contains("airpods") {
                return .airPods
            }
            if ["beats", "headphone", "buds", "kopfhörer"].contains(where: lowered.contains) {
                return .headphones
            }
            if lowered.contains("homepod") {
                return lowered.contains("mini") ? .homePodMini : .homePod
            }
            return .bluetooth
        case .airPlay:
            if lowered.contains("homepod") {
                return lowered.contains("mini") ? .homePodMini : .homePod
            }
            if lowered.contains("apple tv") || lowered.contains("appletv") {
                return .appleTV
            }
            return .airPlay
        case .carAudio:
            return .car
        case .hdmi:
            return .hdmi
        case .usb:
            return .usb
        case .lineOut:
            return .lineOut
        }
    }

    static func route(port: AudioOutputPort, name: String, deviceName: String) -> AudioRoute {
        let kind = kind(port: port, name: name)
        return AudioRoute(name: kind == .speaker ? deviceName : name, kind: kind)
    }
}
