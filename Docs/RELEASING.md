# Releasing Hearth (TestFlight)

Every push to `main` that touches code builds a signed App Store archive in GitHub Actions and uploads it to TestFlight (`.github/workflows/testflight.yml`). The build number is the latest TestFlight build number + 1. The workflow can also be started manually (Actions → TestFlight → Run workflow) with custom "What to Test" notes.

The pipeline uses [fastlane](https://fastlane.tools):

| Lane | What it does |
|---|---|
| `fastlane test` | Runs the HearthKit package tests |
| `fastlane build` | Compiles the iOS app (incl. widgets + watch app) and the watchOS app for the simulator |
| `fastlane bootstrap` | **One-time, local**: registers bundle IDs, capabilities, the app group and the App Store Connect app, and creates signing certificates/profiles with `match` |
| `fastlane certificates` | Installs the signing assets read-only (used by CI) |
| `fastlane beta` | Builds, signs and uploads to TestFlight |

## One-time setup

You need a paid Apple Developer account.

1. **Signing repository.** Create an empty **private** GitHub repository for certificates, e.g. `robinferch/hearth-certificates`.
2. **App Store Connect API key.** In App Store Connect → Users and Access → Integrations → App Store Connect API, create a key with the *App Manager* role. Note the **Key ID** and **Issuer ID** and download the `.p8` file.
3. **Bootstrap** (on your Mac, from the repo root):
   ```sh
   bundle install
   export APPLE_TEAM_ID=XXXXXXXXXX                       # developer.apple.com → Membership
   export FASTLANE_APPLE_ID=you@example.com              # Apple ID (2FA prompt)
   export MATCH_GIT_URL=https://github.com/robinferch/hearth-certificates.git
   export MATCH_PASSWORD='choose-a-strong-passphrase'    # encrypts the signing repo
   bundle exec fastlane bootstrap
   ```
   This creates:
   - the App IDs `me.robinferch.hearth`, `.widgets`, `.watchkitapp` and `.watchkitapp.widgets`;
   - the app group `group.me.robinferch.hearth`;
   - the App Store Connect app "Hearth" (if the name is taken, set `HEARTH_APP_NAME`);
   - App Store distribution profiles for all four App IDs.
4. **GitHub secrets.** In `robinferch/hearth` → Settings → Secrets and variables → Actions, create an environment **`testflight`** with these secrets:

   | Secret | Value |
   |---|---|
   | `APPLE_TEAM_ID` | Your team ID |
   | `APP_STORE_CONNECT_API_KEY_ID` | Key ID |
   | `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID |
   | `APP_STORE_CONNECT_API_KEY_CONTENT` | `base64 -i AuthKey_XXXX.p8 \| pbcopy` |
   | `MATCH_GIT_URL` | URL of the signing repository |
   | `MATCH_PASSWORD` | The match passphrase |
   | `MATCH_GIT_BASIC_AUTHORIZATION` | `echo -n "robinferch:<PAT with repo scope>" \| base64` |

   Then set the repository **variable** `TESTFLIGHT_ENABLED` to `true`. Until it is set, the TestFlight workflow is skipped.

   Optional repository **variables**:
   - `XCODE_VERSION` (default `latest-stable`);
   - `HEARTH_ENTITLEMENTS` (default `Full`; set it to `CarPlay` once Apple granted the CarPlay audio entitlement, then re-run `fastlane match appstore --force` locally so the profiles include it).

## Entitlement variants

`HEARTH_ENTITLEMENTS` selects `App/Support/iOS/Hearth-<variant>.entitlements`:

- `Basic`: keychain sharing and the app group. Use it for local development, including with a free account.
- `Full`: adds iCloud key-value storage (synced library settings) and Siri.
- `CarPlay`: `Full` plus `com.apple.developer.carplay-audio`. Apple has to grant this entitlement; [request it here](https://developer.apple.com/contact/carplay/).

## Versioning

`MARKETING_VERSION` lives in `Configuration/Base.xcconfig`; bump it for a new release. CI sets `CURRENT_PROJECT_VERSION` automatically.
