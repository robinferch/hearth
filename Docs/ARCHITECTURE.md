# Hearth architecture

Hearth is a native SwiftUI client for [audiobookshelf](https://www.audiobookshelf.org) on iPhone, iPad and Apple Watch.

## Layout

```
project.yml                 XcodeGen spec (source of truth for Hearth.xcodeproj)
Configuration/              xcconfig files (copy Local.xcconfig.template → Local.xcconfig)
App/iOS/                    iOS & iPadOS app target (SwiftUI app, CarPlay scene)
App/Widgets/                WidgetKit extension: widgets, Control Center controls, Live Activities
App/Watch/                  watchOS app
App/WatchWidgets/           watchOS widgets / complications
Packages/HearthKit/         Swift package with all shared code
  HearthModel               Pure value types (items, identifiers, sorting, sleep timer, …). No I/O.
  HearthAPI                 audiobookshelf HTTP + Socket.IO client, auth (password, OpenID/PKCE)
  HearthData                Persistence (SwiftData), Keychain, settings, sync, downloads, caches, snapshot for widgets
  HearthPlayback            AVFoundation player, queue, sessions, sleep timer, Now Playing, remote commands
  HearthUI                  Shared SwiftUI components used by the app, widgets and watch (covers, progress, formatting)
  HearthIntents             App Intents, entities and App Shortcuts (shared by app + widgets)
Docs/Spec/                  Functional specs
```

App folders are **synchronized folders** – adding a file to `App/iOS` automatically adds it to the target; no regeneration needed. Run `xcodegen generate` only when `project.yml` changes.

## Dependency direction

`HearthModel` ← `HearthAPI` ← `HearthData` ← `HearthPlayback` ← `HearthIntents`; `HearthUI` depends on Model + Data (+ Playback where needed). Apps depend on everything.

The files named `*Contract.swift` define the public surface each module guarantees. Signatures there are stable; implementations may live elsewhere.

## Conventions

- Swift 6 language mode, strict concurrency. UI-facing state is `@MainActor @Observable`. Networking lives in `Sendable` types/actors.
- Minimum OS: iOS 26, watchOS 26. Use current APIs (Liquid Glass, `TabView` with `Tab`, `tabViewBottomAccessory`, `@Observable`, SwiftData, Swift Testing, `ControlWidget`, App Intents).
- Every user-visible string is localizable (String Catalogs, English source + German). Use `String(localized:)` / `LocalizedStringKey` – never hard-code display strings without localization.
- No third-party dependencies unless unavoidable. (Socket.IO is implemented with `URLSessionWebSocketTask`.)
- Item identity is always `ItemIdentifier` (string-convertible; used in URLs, intents, widgets, Handoff).
- Logging via `os.Logger` (subsystem = bundle id, category = type name).
- Tests use Swift Testing (`import Testing`). Run package tests with `swift test` inside `Packages/HearthKit` (macOS host).

## Build

```sh
xcodegen generate   # only after changing project.yml
xcodebuild -project Hearth.xcodeproj -scheme Hearth -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Hearth.xcodeproj -scheme HearthWatch -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
cd Packages/HearthKit && swift build && swift test
```
