# Uchiyomi for iPhone

The iOS client is a native SwiftUI/WebKit wrapper for your chosen Uchiyomi server. It downloads and verifies the server's web app for offline launch; the IPA contains only the native client. Minimum iOS: 17. This branch is a **test candidate**, with remaining device and AltStore checks listed below.

## Compatible server

Use an HTTPS **origin** with a certificate trusted by iOS, for example `https://books.example.com:8443`. Password sign-in, including TOTP 2FA, is supported. URL subpaths, client certificates, desktop servers, and external/SSO-only sign-in are unsupported.

A compatible server must serve `/mobile-assets.json` publicly as JSON on the same origin. The normal `npm --prefix web run build` now creates this inventory automatically. Both `Dockerfile.aio` and the split web/nginx build include it. Existing upstream releases without this patch cannot prepare the app yet.

The inventory specifies protocol **1**, offline storage schema **2**, every static export asset, byte sizes, hashes, and a deterministic build ID. It includes reader route documents, Next route payloads, and lazy chunks. New builds also acknowledge successful startup. Keep frontend and backend versions matched; do not deploy the current export over an older backend. See [Docker prototype deployment](../ios/DOCKER-PROTOTYPE.md) for a reversible version-matched static mount.

## First use

1. Enter your server address and tap **Connect to server**. Preparation needs a connection and enough free storage; the keyboard dismisses as it starts.
2. Sign in to Uchiyomi. The wrapper does not save your password. Refresh/image cookies are stored in the device Keychain for that server.
3. Download chapters using Uchiyomi's existing offline controls. Wait for each download to finish before going offline.
4. Open Downloads to read offline. The native app can cold-launch without the server after preparation. Progress queues locally and syncs to its original account after reconnecting.

Safari/PWA storage is separate and is not imported. Signing out or expiration of the offline identity requires another online sign-in before reading that account's downloads. Removing the app or OS removal of website data can remove local chapters; the server remains the library's durable copy. Network transfers and progress sync resume in the foreground; background downloading and native push notifications are not implemented.

## Servers and recovery

The reader's **… → Servers** menu switches saved profiles or adds another server. Each has a persistent WebKit store, local address, UI cache, and cookie jar. Switching stops the old web view and its requests. Selecting an existing profile preserves its downloads.

The trash button requires confirmation. Removal deletes that server's **local** session, downloaded chapters, cached app, and unsynced progress. It does not delete the remote library or another profile. Reconnect first if you need pending progress synced.

**Check for reader updates** downloads a separate verified generation while the current reader stays open. **Apply update** activates it and reopens the current location. The previous confirmed version is retained. Failed startup offers **Restore previous reader** or **Download reader again**. These operations replace only UI files, preserving chapters, identity, and queued progress. Unsupported protocol/storage schema changes are refused; the wrapper does not downgrade an offline database. Older compatible UI without a startup acknowledgement asks you to confirm that it opened correctly.

## Developer installation

Install Xcode and finish its first-launch setup. Open `ios/Uchiyomi.xcodeproj`, select the shared **Uchiyomi** scheme and your phone. Enable Developer Mode and trust the Mac. Select your Apple developer team and a unique bundle identifier in ignored `ios/Local.xcconfig`:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
PRODUCT_BUNDLE_IDENTIFIER = your.reverse.domain.uchiyomi
UCHI_TEST_BUNDLE_IDENTIFIER = your.reverse.domain.uchiyomi.webview-tests
```

Use **Run** for a direct device install. Keep the effective bundle ID and signing team stable for updates. Build numbers must increase; neither uninstall the existing app nor reset its data to test an upgrade.

### Archive and IPA

From the repository root, after the checks below:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
bash ios/scripts/package.sh ios/build/candidate-5
# For a later candidate, use a NEW output directory and a higher number:
UCHI_BUILD_NUMBER=6 bash ios/scripts/package.sh ios/build/candidate-6
```

The script archives Release for physical iOS, verifies its signature, and wraps the development-signed archived app in `Payload/Uchiyomi.app`. It fails rather than overwriting an output directory. Outputs:

- `Uchiyomi.ipa` and `SHA256SUMS`.
- `release.json`: version/build, effective bundle/team identity, minimum iOS, entitlements, checksum, actual profile expiration, and explicit verification flags.
- `source.json`: Git revision, dirty state, and hashes of non-ignored working sources. Signed builds are not promised byte-identical; this records the exact candidate's inputs and artifact.
- Archive, build log, signing details, and decoded local provisioning profile. Provisioning files can include registered device identifiers; share the IPA and `release.json`, not the whole build directory.

No App Store export or upload occurs. This packaging path needs the configured development certificate/profile; AltStore will replace the signature. The app requests local networking for LAN servers, uses its own Keychain session items and loopback-only WebKit domain, and has no push, app-group, iCloud, JIT, or associated-domain entitlement. Inspect `release.json` for the actual signature rather than assuming a fixed expiration.

### Automated IPA releases and AltStore source

The [iOS beta workflow](../.github/workflows/ios-release.yml) supports pull requests, manual **Run workflow** builds, and `ios-v*` release tags. It uses GitHub's `xcode-27` runner with Xcode 27.1 and Node 24, runs packaging regressions and native core tests, creates the device IPA, then builds the frontend fixture and runs the real WebKit/lifecycle tests on iPhone Duo. Publishing waits for all checks. The database-dependent native TOTP case remains gated in this job; its separate fixture and physical acceptance are documented above.

New packages require the **iOS 27.1 SDK or later** for the Duo's full display; the deployment minimum remains **iOS 17**. Packaging records the actual SDK/Xcode build in `release.json` and rejects older SDKs. Earlier CI build1005 used iOS26.2 and is letterboxed on the Duo, whereas local builds used iOS27.2. Historical releases remain verifiable in the source. See [Apple's Duo SDK/layout guidance](https://developer.apple.com/iphone-duo/prepare/) and the [hosted runner's installed toolchains](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md).

Manual/PR runs produce downloadable Actions artifacts and an **unpublished source preview**. Preview URLs describe where a future release would live; they are not promised to resolve. Tag runs publish a GitHub **prerelease** with the IPA, `SHA256SUMS`, and `release.json`. They never move the main GitHub latest release or trigger the existing Docker `v*` pipeline.

For a local build with the same credential-free packaging mode:

```sh
UCHI_PACKAGE_MODE=altstore UCHI_VERSION=0.1.0 UCHI_BUILD_NUMBER=6 \
  bash ios/scripts/package.sh ios/build/altstore-local-6

python3 ios/scripts/altstore-source.py \
  --records-dir ios/build/altstore-local-6 \
  --repository YOUR_ACCOUNT/YOUR_FORK \
  --base-url https://YOUR_ACCOUNT.github.io/YOUR_FORK \
  --output ios/build/source-preview-6
```

This produces `Uchiyomi-0.1.0-6.ipa` with a local **ad-hoc signature**, empty entitlements, and no personal provisioning profile. AltStore supplies the actual device signature; this IPA cannot be installed directly with Xcode/devicectl as a development-signed app. No Apple credentials or signing certificate are needed for packaging. `UCHI_PACKAGE_MODE=development` remains the default for existing direct-install commands. Keep output directories under ignored `ios/build/` so build artifacts do not enter the source fingerprint.

#### Set up an authorized fork

1. Push the wrapper changes to a repository where you have write access and enable Actions. The workflow file must be on its default branch for the **Run workflow** button to be available. The workflow derives owner/repository URLs from `github.repository`; it has no dependency on an upstream publishing token. Public release assets are required for the public AltStore feed.
2. Review [listing.json](../ios/distribution/listing.json). Its release bundle ID is explicitly `ca.box.nv.uchiyomi`, matching the current prototype. CI does not inherit ignored `Local.xcconfig`. Keep the ID stable for update continuity; changing the listing ID after publishing requires a separate source/history. Edit the display/developer text for your fork before publication. The existing app icon is copied into the generated site; screenshots are optional and currently omitted.
3. Run **iOS beta → Run workflow** on the branch first. Download the IPA and test an AltStore install/update. This is required evidence before treating the distribution path as device-verified.
4. To publish an iOS beta, push a new tag, for example `ios-v0.1.0-beta.1`. Accepted tags are `ios-vMAJOR.MINOR.PATCH` or `ios-vMAJOR.MINOR.PATCH-beta.N`. The tag supplies the marketing version. The CI build number is `1000 + github.run_number`; reruns keep the same number. All releases from this workflow remain prereleases. Use a fresh tag for a changed binary.
5. To enable the public feed, set **Settings → Pages → Source** to **GitHub Actions**, allow `ios-v*` tags in the `github-pages` environment's deployment rules, and add repository variable **`IOS_ALTSTORE_PUBLISH=true`** before the next release. The workflow deploys the repository's Pages site; use a dedicated fork or integrate this job with an existing site before enabling it. A custom Pages domain is supported through the Pages action's configured base URL.
6. Add the published site's **`/altstore.json`** URL to AltStore Classic. The generator lists all published iOS versions, newest native version/build first, and declares the IPA's local-network permission. It includes a SHA-256 for each IPA. Your AltStore account/AltServer still handle signing and refresh.

The publication job stages a draft, uploads versioned assets, downloads them for verification, then publishes it. Retries may resume identical partial uploads, but refuse to overwrite different bytes. Rerun a failed publication job using its existing build artifact; rerunning the entire workflow may rebuild different ZIP/signature bytes and deliberately fail the immutable-asset check. Actions artifacts expire after 14 days; published Release assets remain available.

When enabled, source publication downloads and verifies every advertised **public** release before deploying Pages. Missing assets, metadata/hash/permission/identity conflicts, or network errors stop that deployment and preserve the previous live feed. The source is rebuilt from Release history, so input ordering or a retry cannot silently put an older native version first. Keep historical release assets available. The app itself still obtains reader UI updates from its chosen server independently of native IPA updates.

Local checks:

```sh
python3 -m unittest discover -s ios/Tests/Distribution -v
actionlint .github/workflows/ios-release.yml
shellcheck ios/scripts/package.sh ios/scripts/test-webview.sh
# Requires web/out from npm --prefix web run build; creates/deletes its own simulator.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  bash ios/scripts/test-webview.sh ios/build/WebViewLocal
```

Each publishing fork must verify its hosted Xcode build and GitHub Release/Pages jobs. Local script, archive, source-preview and simulator results do not substitute for hosted execution or a source-based phone install/update.

The testing fork is [nVitius/uchiyomi](https://github.com/nVitius/uchiyomi). Use its [iOS beta workflow](https://github.com/nVitius/uchiyomi/actions/workflows/ios-release.yml) for manual builds and its [releases](https://github.com/nVitius/uchiyomi/releases) for published IPAs. Its configured AltStore source is `https://nvitius.github.io/uchiyomi/altstore.json`, populated after a successful iOS tag release. Test betas keep device and AltStore acceptance marked pending until installation/update checks are recorded.

The first public test release is [0.1.0 (1005), beta 3](https://github.com/nVitius/uchiyomi/releases/tag/ios-v0.1.0-beta.3). Its [hosted build, release and Pages jobs](https://github.com/nVitius/uchiyomi/actions/runs/41290404805) passed; the public IPA, checksum, metadata, feed, icon and landing page were independently downloaded and verified. Publication required one retry because GitHub's draft listing lagged; subsequent publisher code resolves draft identity directly through GraphQL and reads assets by release ID. Source-based phone installation and update acceptance remain pending.

References: [AltStore source format](https://faq.altstore.io/developers/make-a-source), [version ordering](https://faq.altstore.io/developers/updating-apps), [GitHub Pages workflows](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages).

## AltStore Classic

Follow the official [macOS installation guide](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos): install AltServer on your Mac, connect/unlock the iPhone, enable Finder's Wi-Fi visibility, then choose **Install AltStore → your phone** from AltServer. Complete Apple account authentication locally and trust the developer if iOS requests it. Developer Mode must be enabled.

Transfer `Uchiyomi.ipa` to Files on the iPhone and import it using **My Apps → +** in AltStore Classic, completing its signing flow. Keep AltServer reachable for signing/refresh as required by your setup. Review the expiration and effective identity shown by AltStore. See [AltStore's My Apps/account guide](https://faq.altstore.io/altstore-classic/your-altstore) for refresh and account limits.

Treat an AltStore install as its own installation channel: re-signing can change the effective app identity. Existing Xcode data is not promised to migrate between channels or teams. For the continuity test, prepare/download in AltStore, then import a later native build through the **same AltStore account and identity** without removing the app. A test beta may be published after artifact verification to exercise source installation; keep its device/AltStore verification flags false until those checks pass.

## Verification

```sh
npm --prefix web ci
npm --prefix bff ci
npm --prefix web run build
npm --prefix web test
npm --prefix bff run build
# BFF integration tests need a disposable PostgreSQL database:
TEST_DATABASE_URL=postgres://test:test@127.0.0.1:5432/uchiyomi_test npm --prefix bff run test:ci
node --test ios/scripts/manifest.test.mjs
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash ios/scripts/test-core.sh
# Starts/removes a disposable local PostgreSQL Docker container; never use a live database.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash ios/scripts/test-auth.sh
```

The native auth test uses the real BFF password/TOTP/refresh/logout routes. `test-core.sh` skips that database-dependent case unless `TEST_DATABASE_URL` is set. Gateway tests verify bounded binary streaming, cancellation, cookie isolation, blocked redirects, cached routes and listener restart. Cache tests cover corruption, interrupted updates, changed manifests, unsupported schemas, and disk-write failure.

The BFF CI runner creates a separate disposable database for each test file. Run the full suite on Linux for its GNU tar, case-sensitive filesystem, and Linux-only translation fixtures. On macOS, `TMPDIR=/private/tmp` avoids failures caused by the system temporary-directory symlink; it does not make those Linux-specific fixtures portable.

Run the real frontend WebKit suite on an installed simulator, keeping default signing for Keychain access:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project ios/Uchiyomi.xcodeproj -scheme Uchiyomi -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.2' \
  -derivedDataPath ios/build/SimulatorTests test
```

WebKit fixtures verify offline reader routes, data after UI update/broken startup/rollback, and two servers with identical user/chapter IDs. Reader lifecycle tests also exercise overlapping server actions and callbacks from retired web views. Test resources are only in the test bundle, never the packaged app. Simulator checks do not establish physical cold-launch, reboot, or signing behavior.

### Device evidence and remaining acceptance

Direct developer builds **1–2**, iPhone Duo / iOS 27.2, version-matched Uchiyomi v0.101.0 frontend/backend:

- UI prepared; password login; two chapters downloaded before their reader routes were visited.
- Airplane Mode with Wi-Fi off: cold launch, both chapters, saved position, another force-quit/reopen, and a full device reboot all passed.
- Reconnection: session restored, an undownloaded online chapter loaded, and offline progress matched the same account in Safari/PWA.
- Native build 2 update retained server, session, chapters, and position. Progress had already synced before that update.

**Build 5 was an earlier candidate.** It prevents overlapping server/update transitions and ignores startup callbacks from retired readers. Subsequent beta work also fixes a profile-switch cancellation crash found by hosted CI; use the newest published beta for testing. Profile/update/transport behavior requires device checks. Real TOTP is verified through the native transport/BFF fixture, not a human phone sign-in. Remaining acceptance includes foreground/rotation/external-link checks, partial downloads, logout/expired identity and account switching on-device, pending-progress retention across a native update, and AltStore installation/update/cold-offline/reboot flows. Record the IPA checksum and effective signing identity with each run. Do not label a candidate device-verified from earlier builds' results.

### Next phone session

Record the candidate build/checksum, iOS version, installation channel, effective signing identity, and expiration. Keep the existing app installed. A fresh AltStore identity can have separate data from the Xcode installation.

1. **Install and prepare:** import the verified IPA; report whether it opens the saved library or a fresh connection screen. If fresh, connect and sign in, then download two chapters before opening their reader routes.
2. **Offline and lifecycle:** enable Airplane Mode and turn Wi-Fi off. Force-quit/reopen, read both chapters, change the position in the second, rotate, and background/foreground the app. Reboot while offline and check both chapters and position again.
3. **Native update with pending progress:** while offline, move to a new position and force-quit. Restore networking for AltStore installation while keeping Uchiyomi closed. Import a later build with the same identity. Before opening Uchiyomi, turn Airplane Mode on and Wi-Fi off again. Verify server, account, both chapters, and the new position. Then reconnect, open Uchiyomi, and verify that the same account in Safari/PWA receives the position. Repeat in the direct developer channel to establish both update paths.
4. **Online surfaces:** open an undownloaded chapter without signing in again. Check safe areas in both orientations, an external link, and a copied share link; the share link must use the public server address.

Separate guided checks remain for interrupted downloads, sign-out/expired offline identity, account/server isolation, and applying/recovering a changed UI while chapters and progress are saved. Use disposable accounts/profiles for destructive checks. A successful check for updates when the server is already current does not establish update/recovery behavior.
