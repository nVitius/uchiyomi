# Native navigation experiment verification

Verification through 2026-11-04. The matching backend/frontend is deployed to the private test server. Hosted native build 1019, including the adaptive-bar correction, is published to the existing AltStore test channel. The user's follow-up screenshot confirms individual side-dock icons, with a request to close the gap and move the secondary menu below them. That refinement is implemented locally and remains unpublished; its current coverage is recorded below. Full physical-device acceptance remains pending. Local candidates numbered 1016 remain unpublished. The protocol and remaining device checklist are in [HOST-NAVIGATION.md](HOST-NAVIGATION.md).

## Contiguous dock refinement (unpublished)

The primary actions and secondary menu now share one system toolbar group when `toolbarVerticalEdge` is present. Following the user's preview feedback, the group uses top-toolbar placement: it anchors below the system status controls and grows downward. The menu follows You and uses a plain white ellipsis. Horizontal layouts retain native tabs and More overflow. Primary actions hide during reading/loading; the same web view, store and bridge remain in use. The vertical viewport also removes the unused horizontal bar reserve while keeping UIKit's safe-area protection and native notice insets. This is a native-only change; it needs no frontend or server update.

Final focused runs use the existing `NativeNavigationTests` suite, Debug, SDK 27.2 and deployment target 17:

| Result bundle under `ios/build/` | Runtime / pose | Result |
| --- | --- | --- |
| `navigation-menu-top-verified-duo.xcresult` | Duo / iOS 27.2 (24B91016s), folded outer display, 466×678 | All 3 cases passed, zero failures. |
| `navigation-menu-top-verified-phone.xcresult` | iPhone 18 Pro / iOS 27.2 (24B8117), portrait | All 3 cases passed, zero failures. |

The full ReaderView test measures the primary actions and menu in order on the same vertical axis, bounds adjacent spacing, checks content clearance and the absence of an extra bottom reserve, and verifies menu availability while primary actions hide in the reader. It also asserts that the menu alone occupies the top region and that the full group starts at that same position when primary actions return, growing downward. The system status region is not part of the ordinary window safe-area inset, so comparing raw space above/below the group would incorrectly count that reserved region as an app gap. Existing checks retain document/view/store/delegate identity through Servers, notices, resizing and profile replacement. The other two cases cover native tab/More ownership and the real offline frontend with legacy fallback.

Exported Duo attachments are local in `navigation-menu-top-verified-duo-attachments/`; the unchanged horizontal phone presentation was visually checked in `navigation-menu-complete-phone-attachments/`. Visual inspection confirms one continuous Duo dock growing downward from the top and ending in the white ellipsis, ordinary horizontal phone tabs, and the phone's menu during immersive reading. The horizontal SwiftUI navigation bar does not expose an identified menu UIView to the hosted test, so that menu check uses the captured image; vertical menu identity and geometry are asserted directly. Screenshots are not committed.

The Mac was locked during this refinement, preventing Device Hub interaction to unfold or rotate the Duo simulator. Inner-display poses, folding transitions, large text, VoiceOver and physical-device acceptance remain unverified for this candidate. The earlier pose results below belong to build 1019's implementation and do not close those gaps. No release tag, feed or live server was changed.

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

These 12 cases retain the existing single-view/store/document, Servers/notices, immersive reading, resize, offline frontend and legacy fallback coverage. Before/after screenshots are local result attachments. The subsequent full local WebKit run and hosted release checks are recorded below; the full browser walk was not repeated for this native layout modifier. Build 1019 is published, but confirmation on the physical Duo remains pending; earlier device results do not validate this correction.

The first publication attempt, tag `ios-v0.1.0-beta.13` / build 1016, was blocked by hosted WebKit failures in [run 41784753056](https://github.com/nVitius/uchiyomi/actions/runs/41784753056). Attempt 1 exceeded the prepared-reader deadline and subsequently logged completion at 318 seconds; its timeout snapshot includes system I/O throttling. On the unchanged second attempt, that case passed, but automatic rollback did not finish within the fixture's wait while the simulator GPU process was unresponsive. All three navigation cases passed on both attempts. No release or feed update occurred. Diagnostics are retained in `ios/build/navigation-published-1016/failure*`.

The next candidate pins hosted Xcode and the Duo runtime to 27.2, matching the local QA series, and installs the runtime when absent from the runner image. Tag `ios-v0.1.0-beta.14` / build 1017 stopped before WebKit testing because requesting version `27.2` downloaded the standard `24B114` runtime without Duo support. The workflow now requests the specific Duo build `24B91016s`; that exact download command was verified locally.

Tag `ios-v0.1.0-beta.15` / build 1018 successfully installed the Duo runtime. Its hosted update and prepared-reader cases passed, but the subsequent two-server fixture exceeded five minutes. The timeout snapshot again shows the WebKit networking process in kernel I/O throttling. The full local suite on the corrected code passed 12 main cases and the separate authentication case (`ios/build/navigation-runtime-local-retry/`); its initial local attempt encountered an occupied random fixture port. These results suggest simulator/fixture interaction but do not establish the underlying WebKit cause.

The runner now extends the existing authentication isolation to each of the three cache fixtures, retaining the main navigation/lifecycle and authentication invocations. All five invocations must pass. Assertions and time limits are unchanged, and CI preserves all result bundles. The revised runner passed locally: 9 main cases, each of the three cache cases, and authentication (13 passed total; one opt-in installation skip). Evidence: `ios/build/navigation-isolated-cache/summary.json`. The subsequent hosted build 1019 passed all five invocations, as recorded below. Some hosted cases remained slow; this successful run does not establish that all simulator timing variability is resolved.

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

### Adaptive-bar correction: build 1019

- Published `0.1.0` (build `1019`), tag [`ios-v0.1.0-beta.16`](https://github.com/nVitius/uchiyomi/releases/tag/ios-v0.1.0-beta.16), from source `595aa158e8021fe3ee46169964e214b4cd4236c4`. The existing bundle and feed identity are preserved. This correction needs no server update.
- [Actions run 41793498271](https://github.com/nVitius/uchiyomi/actions/runs/41793498271) passed build, release and source deployment. All 13 required WebKit cases passed across five invocations on the iOS 27.2 Duo runtime; the opt-in installation test was skipped. Assertions and execution limits were retained.
- Independent public verification at 08:03:11 UTC on 2026-11-04 checked the IPA checksum, size, SDK, ad-hoc signature, empty entitlements, absent personal provisioning, exact source fingerprint and bundle identity. The AltStore feed advertises build 1019 and preserves every historical entry.
- Earlier tags beta.13–beta.15 were blocked before publication. Their diagnostics and the locally verified CI adjustments are documented above. Physical installation, folding/accessibility and update retention of build 1019 remain pending.

IPA SHA-256: `cf2f74af2ad623a3f064d94cadfcd6bd4fc4dccf03a0df6b2bf8a5b78c35f67b` (967,989 bytes), SDK `iphoneos27.2`. Evidence: `ios/build/navigation-published-1019/`.

### Initial navigation experiment: build 1015

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
