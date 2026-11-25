# Privacy Policy

Hearth is an open-source client for self-hosted [audiobookshelf](https://www.audiobookshelf.org) servers.

- **No data collection.** Hearth contains no analytics, tracking, advertising or crash-reporting SDKs. The developer receives no data from the app.
- **Your servers only.** Hearth talks only to the audiobookshelf servers you add. Your listening progress, bookmarks and listening sessions are sent to those servers so they stay in sync.
- **On your devices.** Server addresses, user names and access tokens are stored in the system Keychain. Downloads, caches and settings stay on your device. If iCloud is enabled, some library display settings (for example sort order) sync through your private iCloud key-value store, and connection details sync through iCloud Keychain.
- **Transcripts and ads.** Transcription runs on your device. Ads are found on your device (Apple Intelligence or keywords) – unless you choose Claude and enter your own Anthropic API key: then the transcript text (never the audio) is sent to Anthropic under [Anthropic's privacy policy](https://www.anthropic.com/legal/privacy) and billed to your Anthropic account. The key is stored in the Keychain on your device.
- **Apple services.** Siri, Shortcuts, Spotlight, widgets, CarPlay and Apple Watch features run on-device or through Apple's frameworks under Apple's privacy policy.

Questions: open an issue at https://github.com/robinferch/hearth/issues.
