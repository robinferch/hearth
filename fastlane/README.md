fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios generate

```sh
[bundle exec] fastlane ios generate
```

Generate Hearth.xcodeproj from project.yml

### ios test

```sh
[bundle exec] fastlane ios test
```

Run the HearthKit package tests

### ios build

```sh
[bundle exec] fastlane ios build
```

Compile the iOS app (incl. widgets and watch app) and the watchOS app for the simulator

### ios bootstrap

```sh
[bundle exec] fastlane ios bootstrap
```

One-time setup on a Mac: registers bundle IDs, capabilities, the app group, the App Store Connect app and creates signing assets with match

Requires FASTLANE_APPLE_ID (interactive 2FA), APPLE_TEAM_ID and MATCH_GIT_URL

### ios certificates

```sh
[bundle exec] fastlane ios certificates
```

Fetch signing assets (read-only) for App Store builds

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Build a signed App Store archive and upload it to TestFlight

### ios metadata

```sh
[bundle exec] fastlane ios metadata
```

Upload App Store metadata (fastlane/metadata) and the screenshots exported to Marketing/AppStore/export

Run Marketing/AppStore/export.sh first. Nothing is submitted for review.

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
