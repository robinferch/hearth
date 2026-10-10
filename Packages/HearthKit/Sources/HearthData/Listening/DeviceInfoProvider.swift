import Foundation
import HearthAPI

/// Builds the `DeviceInfo` sent with playback sessions.
enum DeviceInfoProvider {
    static let deviceIDKey = "deviceID"

    /// Persistent random device id stored in the app group defaults (shared by app, widgets and intents).
    static func deviceID(defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: deviceIDKey), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: deviceIDKey)
        return id
    }

    /// Hardware model identifier such as `iPhone17,1` (simulators report the simulated model).
    static func modelIdentifier() -> String {
        let environment = ProcessInfo.processInfo.environment
        if let simulated = environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        if ProcessInfo.processInfo.isiOSAppOnMac {
            return "Mac (\(machine))"
        }
        return machine.isEmpty ? "Unknown" : machine
    }

    static func osName(model: String) -> String {
        #if os(watchOS)
        "watchOS"
        #elseif os(iOS)
        model.hasPrefix("iPad") ? "iPadOS" : "iOS"
        #elseif os(macOS)
        "macOS"
        #elseif os(visionOS)
        "visionOS"
        #else
        "iOS"
        #endif
    }

    static func osVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    static func appVersion(bundle: Bundle = .main) -> String {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return short?.isEmpty == false ? short! : "1.0"
    }

    static func make(defaults: UserDefaults) -> DeviceInfo {
        let model = modelIdentifier()
        return DeviceInfo(deviceID: deviceID(defaults: defaults), clientVersion: appVersion(), model: model, osName: osName(model: model), osVersion: osVersion())
    }
}
