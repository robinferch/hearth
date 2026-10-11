import AVFoundation
import Foundation
import HearthModel

#if os(iOS) || os(watchOS)
#if os(iOS)
import UIKit
#endif

/// AVAudioSession configuration, interruptions, route changes and the current output route.
extension AudioPlayer {
    func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio, options: [])
        } catch {
            logger.error("Configuring the audio session failed: \(error.localizedDescription, privacy: .public)")
        }

        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleInterruption(type: type, options: options)
            }
        })
        notificationTokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleRouteChange(reason: reason)
            }
        })
        notificationTokens.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleMediaServicesReset()
            }
        })

        updateRoute()
    }

    func activateAudioSession() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        #if os(watchOS)
        // Presents the route picker when no Bluetooth output is connected.
        do {
            return try await session.activate(options: [])
        } catch {
            logger.error("Activating the audio session failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        #else
        do {
            try session.setActive(true)
        } catch {
            // AVPlayer activates the session implicitly; keep going.
            logger.error("Activating the audio session failed: \(error.localizedDescription, privacy: .public)")
        }
        updateRoute()
        return true
        #endif
    }

    func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            logger.debug("Deactivating the audio session failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func handleInterruption(type rawType: UInt?, options rawOptions: UInt?) {
        guard let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            let wasPlaying = isPlaying || intendsToPlay
            intendsToPlay = false
            player?.pause()
            if lastPauseDate == nil {
                lastPauseDate = .now
            }
            resumeAfterInterruption = wasPlaying
            syncPlayingState()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions ?? 0)
            let shouldResume = options.contains(.shouldResume) && resumeAfterInterruption
            resumeAfterInterruption = false
            if shouldResume {
                resume()
            }
        @unknown default:
            break
        }
    }

    func handleRouteChange(reason rawReason: UInt?) {
        updateRoute()
        guard let rawReason, let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else { return }
        if reason == .oldDeviceUnavailable, intendsToPlay || isPlaying {
            // Headphones unplugged: the system pauses; reflect it.
            pause()
        }
    }

    func handleMediaServicesReset() {
        logger.warning("Media services were reset")
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio, options: [])
        guard currentItem != nil else { return }
        Task {
            await rebuildPlayerItems(refreshHeaders: false)
        }
    }

    func updateRoute() {
        let session = AVAudioSession.sharedInstance()
        guard let output = session.currentRoute.outputs.first else {
            route = AudioRoute(name: Self.deviceName, kind: .speaker)
            return
        }
        let newRoute = AudioRouteClassifier.route(port: Self.outputPort(for: output.portType), name: output.portName, deviceName: Self.deviceName)
        if newRoute != route {
            route = newRoute
        }
    }

    static func outputPort(for port: AVAudioSession.Port) -> AudioOutputPort {
        switch port {
        case .builtInSpeaker: .builtInSpeaker
        case .builtInReceiver: .builtInReceiver
        case .headphones: .headphones
        case .bluetoothA2DP: .bluetoothA2DP
        case .bluetoothLE: .bluetoothLE
        case .bluetoothHFP: .bluetoothHFP
        case .airPlay: .airPlay
        case .carAudio: .carAudio
        case .HDMI: .hdmi
        case .usbAudio: .usb
        case .lineOut: .lineOut
        default: .other
        }
    }

    static var deviceName: String {
        #if os(watchOS)
        String(localized: "Apple Watch", bundle: .module)
        #else
        UIDevice.current.localizedModel
        #endif
    }
}

#else

extension AudioPlayer {
    func configureAudioSession() {}
    func activateAudioSession() async -> Bool { true }
    func deactivateAudioSession() {}
    func updateRoute() {}
}

#endif
