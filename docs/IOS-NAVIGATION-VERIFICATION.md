# Native navigation experiment verification

Verification through 2026-11-04 UTC. The matching backend/frontend is deployed to the private test server. Hosted native build 1015 is published to the private AltStore channel; physical-device acceptance remains pending. The adaptive-bar correction below is local and requires a new native release. Local candidates numbered 1016 remain unpublished. The protocol and remaining device checklist are in [HOST-NAVIGATION.md](HOST-NAVIGATION.md).

## Source and compatibility

- Branch: `feat/native-navigation`, created from upstream main `e6047fc7d467a82744d5fcf076bba6ac518e9a8d` plus the published iOS wrapper prerequisite `435f2b73da6ac25f4c5f0921132d25af0636154e` (PR #390).
- The experiment does not change PR #390 or PR #391.
- Frontend package version: `0.103.1`. Use a matching backend; this export is not a drop-in update for an older server backend.
- The private test server was upgraded from `0.101.0` to the matching `0.103.1` backend/frontend with user authorization on 2026-11-02 UTC. Frontend build: `a6d122ebfde74a320b3e3be4962c641c55370a0c449ead2e0c644243cf71617e`; artifact source: `3f23729c31d7d4050203b401d1b3dae8259f3404`.
- Cache protocol remains 1; offline schema remains 2. Navigation protocol 1 is an optional, independently negotiated capability.
- Xcode SDK: iOS 27.2. Deployment target remains iOS 17. An iOS 17 runtime was not available for execution.

## Automated evidence

| Entry point | Result |
| --- | --- |
| `cd web && npm test` | 1,741 passed, including the shared controller with a non-iOS in-memory transport. |
| `cd web && npx tsc --noEmit` | Passed; checked again after restoring Next's generated configuration edits. |
| `cd web && npm run build` | Production export: 182 manifest assets. |
| `web/test/e2e/up.sh` with the final export and fresh disposable database | Passed: zero failures, application console errors or application server errors. The existing harness separately records intentional network cuts and failed third-party covers. |
| `ios/scripts/test-core.sh` | 27 passed; the opt-in real-auth case was skipped here and run separately below. |
| `ios/scripts/test-auth.sh` | Real username/password + TOTP refresh, relaunch and logout passed. |
| Distribution / manifest test entry points | 22 distribution tests and 5 manifest tests passed. |
| `ios/scripts/test-webview.sh ios/build/navigation-verified-phone` | Both invocations passed on iPhone 18 Pro / iOS 27.2 (24B8117): 13 passed, one opt-in installation test skipped. |
| `ios/scripts/test-webview.sh ios/build/navigation-verified-duo` | Both invocations passed on Duo / iOS 27.2 (24B91016s), unfolded 951×669: 13 passed, the same installation test skipped. |
| `navigation-portrait-duo.xcresult` | All 3 navigation cases passed on the rotated inner display, 669×951. |
| `navigation-outer-duo.xcresult` | All 3 navigation cases passed on the folded outer display in landscape, 678×466. |

The hosted suite covers one web view/store/document across all six destinations and system More, Servers, notices, resizing, immersive reading, real offline frontend activation, legacy fallback, main-frame/origin/document validation, profile isolation, cache rollback, process replacement, Home-first launch and offline sign-out. A focused follow-up also asserts that actual native tab enabled states match offline availability.

The browser extension to the existing walk covers all primary/secondary routes, root re-taps, child/root history, rejected actions, Quick settings, live ownership loss and failed handshakes. It hit-tests More's last action, confirmation controls, Filters footer, the editor/extraction dialog, ContinueBar, fixed selection bars and notices at 390, 768, 1023 and 1024 pixels. The extraction response stand-in supplies capability/job metadata only; it does not claim to test the extraction engine.

Screenshots remain local attachments in the result bundles and browser output. The initial simulator runs captured bottom tabs even in vertical-bar poses; that gap was exposed by physical feedback and corrected below. Actual updated-device placement and accessibility remain physical acceptance items. No custom right-edge positioning is imposed.

## Adaptive bar correction

The user's Duo screenshot showed the primary destinations at the bottom while only the secondary menu entered the side dock. The outer SwiftUI navigation stack was insetting the tab controller horizontally, preventing it from reaching the display edge and participating in the vertical bar. The representable now ignores horizontal container safe areas; UIKit still insets the web content, and vertical SwiftUI insets still reserve space for native notices and the toolbar. This is a native-only correction; the deployed frontend and navigation protocol remain compatible.

The existing full `ReaderView` test now checks the tab bar's actual axis against the system's `verticalBarEdge` trait, its reach to the display edge, and clearance from the web viewport. The previous test checked view ownership and positive bounds but could pass with the wrong bar placement.

Focused `NativeNavigationTests` runs on iOS 27.2, 2026-11-04 UTC:

| Local result bundle in `ios/build` | Result |
| --- | --- |
| `navigation-icons-outer.xcresult` | 3 passed on the folded Duo display. |
| `navigation-icons-inner-landscape.xcresult` | 3 passed; screenshot shows all six primary icons in the side dock on the unfolded 951×669 display. |
| `navigation-icons-inner-portrait.xcresult` | 3 passed; screenshot shows horizontal tabs on the unfolded 669×951 display. |
| `navigation-icons-phone.xcresult` | 3 passed on iPhone 18 Pro; ordinary tabs/More remain usable. |

These 12 cases retain the existing single-view/store/document, Servers/notices, immersive reading, resize, offline frontend and legacy fallback coverage. The full unrelated core/auth/browser suites were not repeated for this layout modifier. Before/after screenshots are local result attachments. The updated IPA still needs publication and confirmation on the physical Duo; earlier device results do not validate this correction.

The first publication attempt, tag `ios-v0.1.0-beta.13` / build 1016, was blocked by hosted WebKit failures in [run 41784753056](https://github.com/nVitius/uchiyomi/actions/runs/41784753056). Attempt 1 exceeded the prepared-reader deadline and subsequently logged completion at 318 seconds; its timeout snapshot includes system I/O throttling. On the unchanged second attempt, that case passed, but automatic rollback did not finish within the fixture's wait while the simulator GPU process was unresponsive. All three navigation cases passed on both attempts. No release or feed update occurred. Diagnostics are retained in `ios/build/navigation-published-1016/failure*`.

The next candidate pins hosted Xcode and the Duo runtime to 27.2, matching the local QA series, and installs the runtime when absent from the runner image. Tag `ios-v0.1.0-beta.14` / build 1017 stopped before WebKit testing because requesting version `27.2` downloaded the standard `24B114` runtime without Duo support. The workflow now requests the specific Duo build `24B91016s`; that exact download command was verified locally.

Tag `ios-v0.1.0-beta.15` / build 1018 successfully installed the Duo runtime. Its hosted update and prepared-reader cases passed, but the subsequent two-server fixture exceeded five minutes. The timeout snapshot again shows the WebKit networking process in kernel I/O throttling. The full local suite on the corrected code passed 12 main cases and the separate authentication case (`ios/build/navigation-runtime-local-retry/`); its initial local attempt encountered an occupied random fixture port. These results suggest simulator/fixture interaction but do not establish the underlying WebKit cause.

The runner now extends the existing authentication isolation to each of the three cache fixtures, retaining the main navigation/lifecycle and authentication invocations. All five invocations must pass. Assertions and time limits are unchanged, and CI preserves all result bundles. The revised runner passed locally: 9 main cases, each of the three cache cases, and authentication (13 passed total; one opt-in installation skip). Evidence: `ios/build/navigation-isolated-cache/summary.json`. Hosted verification remains required before publication.

## Reproduce

Build the frontend first. Use the existing disposable browser fixture, with a distinct local image/network/port if another run is active:

```sh
cd web
npm ci
npm test
npx tsc --noEmit
npm run build
cd ..
E2E_IMAGE=uchiyomi:navigation-test E2E_NET=uchiyomi-navigation-test \
  E2E_PORT=18163 E2E_SUBNET=10.225.63.0/24 bash web/test/e2e/up.sh
bash ios/scripts/test-core.sh
bash ios/scripts/test-auth.sh
UCHI_SIMULATOR_ID=<test-device-uuid> bash ios/scripts/test-webview.sh ios/build/navigation-check
```

The WebKit script runs its three cache fixtures and authentication in separate test-host invocations from the navigation/lifecycle group. All five result bundles must pass. Its opt-in installation fixture does not replace a physical in-place-update test.

## Candidate artifacts and release boundary

Prepare a local AltStore candidate with `ios/scripts/package.sh`; it verifies the ad-hoc signature, IPA metadata and a before/after source fingerprint. AltStore supplies the user's final signing. Use the established installation identifier for an existing private test channel; keep the repository's official identifier unchanged. The candidate directory contains `release.json`, `source.json`, checksums and the IPA. Pair it with the verified frontend export and its `mobile-assets.json` manifest.

The server deployment and native beta publication are complete. Physical folding/rotation, keyboard, larger text, VoiceOver, in-place retention, offline reboot and subsequent sync remain open.

## Hosted beta publication

- Published version `0.1.0` (build `1015`), tag `ios-v0.1.0-beta.12`, on the fork's existing AltStore source. CI assigns build numbers independently of the unpublished local candidate numbered 1016.
- Release source `e8fd3803cf7cde9d8bae08bc9e5f166374e4c5d9` contains the verified implementation at `3f23729c` plus deployment documentation and the private channel's existing bundle identifier. The private identifier change is confined to `release/ios-native-navigation`; the feature branch retains the official identifier.
- [GitHub Actions run 41419163049](https://github.com/nVitius/uchiyomi/actions/runs/41419163049) passed its build, release and source jobs. Hosted WebKit on iOS 27.1 passed 12 main cases and the separate authentication case; the existing opt-in installation fixture was skipped.
- Attempt 1 exceeded the prepared-reader test's deadline. Its timeout snapshot showed the simulator networking process inside cookie-setting and kernel disk-I/O throttling; the test subsequently completed its assertions. An unchanged fresh-run attempt passed that case in 24 seconds and completed both test invocations. No assertion, timeout or product code was changed for the retry.
- Independent public verification at 09:50:43 UTC checked the IPA's checksum, size, ad-hoc signature, empty signing entitlements, absent personal profile, exact source fingerprint and bundle identity. The feed advertises build 1015 and preserves every previous release entry.

IPA SHA-256: `c3744980ba14278a9474fd7f47fb6fd60c54d6b09b8d724fcc373a9cf3e42d55` (967,298 bytes). Local evidence: `ios/build/navigation-published-1015/`. Publication does not establish successful installation or physical Duo behavior.

## Private server deployment

The authorized deployment passed local server checks at 09:07:50 UTC and independent public checks at 09:08:36 UTC on 2026-11-02.

- A private database restore, with networking disabled, passed the `0.103.1` migration and preserved account, session, progress, offline-download and library records. The previous `0.101.0` backend also booted successfully against the migrated copy. Disposable staging containers and data copies were removed afterward.
- The deployed backend uses the official `v0.103.1` image with only the compiled wrapper manifest-serving module added. The frontend is mounted read-only. The existing pod, helper containers, environment and persistent mounts were preserved, as were critical database row fingerprints during deployment.
- A cleanly stopped PostgreSQL 16 data backup and configuration backup were verified before activation. The translation model directory was retained unchanged in its existing volume. The old image/frontend and rollback launcher remain available.
- Public health, liveness, authentication configuration, Home, Library, Offline, Reader, service worker and JSON API 404 checks passed. Every one of the 182 assets passed checksum, size and content-type verification (9,438,057 bytes total); the manifest has the expected version/build and no-cache header.

Operational metadata, exact image IDs, launchers and backup paths are retained privately in `ios/build/navigation-candidate-1016/deployment/`. Server delivery alone does not verify native installation or physical-device behavior.
