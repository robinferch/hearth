# Hearth

**Hearth** is a free, open-source, native client for [audiobookshelf](https://www.audiobookshelf.org) on **iPhone, iPad, Apple Watch and CarPlay**, written entirely in Swift and SwiftUI.

> Hearth does not include any media. You need your own audiobookshelf server.

## Features

- **Audiobooks & podcasts**: browse libraries, series, authors, narrators, collections and playlists.
- **Multiple servers and accounts** at the same time, with password or OpenID (SSO) sign-in, custom HTTP headers, and support for self-signed and client certificates.
- **Listen Now and global search** across every connected library.
- **A full player**: chapters, bookmarks, queue and Up Next, adjustable speed, smart rewind, and a sleep timer (by time or by chapter; fade-out; extend by shaking).
- **Offline listening**: background downloads, automatic download rules for series and podcasts, and an offline mode.
- **Progress sync** with your server, offline sessions that are uploaded later, and live updates over WebSocket.
- **Listening statistics** and a daily listening goal.
- **System integration**: widgets (Home Screen, Lock Screen, StandBy), Control Center controls, a Live Activity for the sleep timer, Siri and Shortcuts (App Intents), Spotlight, Handoff, Home Screen quick actions, and CarPlay.
- **Apple Watch app**: play on the watch over Bluetooth headphones, download to the watch, or use it as a remote for your iPhone. Includes complications.
- **iPad**: sidebar navigation, multiple windows, keyboard shortcuts, and pointer support.
- **PDF viewer** for documents attached to a book.

## Requirements

- iOS / iPadOS 26 or later, watchOS 26 or later
- audiobookshelf server 2.26 or later recommended (older versions work with legacy tokens)
- Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) to build

## Building

1. `cp Configuration/Local.xcconfig.template Configuration/Local.xcconfig` and set `DEVELOPMENT_TEAM` and `BUNDLE_ID_PREFIX`.
   - `HEARTH_ENTITLEMENTS = Basic` works with a free Apple developer account.
   - `Full` also enables iCloud sync, Siri and CarPlay. CarPlay requires an entitlement that Apple has to approve.
2. `xcodegen generate` (only needed after `project.yml` changes)
3. Open `Hearth.xcodeproj`, choose the **Hearth** scheme and run.

For OpenID sign-in, add `hearth://oauth` to the allowed redirect URIs in your audiobookshelf authentication settings.

See [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md) for how the code is organized.

## Contributing

Issues and pull requests are welcome. Please keep the code native (SwiftUI, no unnecessary dependencies), localizable and accessible.

## License

[MIT](LICENSE). Hearth is not affiliated with audiobookshelf or Apple.
