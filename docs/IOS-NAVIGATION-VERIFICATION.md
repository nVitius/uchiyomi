# Native navigation experiment verification

Local verification, 2026-11-02 UTC. This candidate has not been published, deployed to a live server or accepted on a physical device. The protocol and remaining device checklist are in [HOST-NAVIGATION.md](HOST-NAVIGATION.md).

## Source and compatibility

- Branch: `feat/native-navigation`, created from upstream main `e6047fc7d467a82744d5fcf076bba6ac518e9a8d` plus the published iOS wrapper prerequisite `435f2b73da6ac25f4c5f0921132d25af0636154e` (PR #390).
- The experiment does not change PR #390 or PR #391.
- Frontend package version: `0.103.1`. Use a matching backend; this export is not a drop-in update for an older server backend.
- The private test server's public manifest still reports frontend `0.101.0` (checked 2026-11-02 UTC). Its deployment needs a version-matched backport or a separately approved backend upgrade/test instance before using this export. No live changes were made.
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

Screenshots remain local attachments in the result bundles and browser output. UIKit selected a bottom tab bar in the captured simulator poses; actual Duo dock placement and accessibility are still physical acceptance items. No custom right-edge positioning is imposed.

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

The WebKit script deliberately runs authentication in a separate test-host invocation. Both result bundles must pass. Its opt-in installation fixture does not replace a physical in-place-update test.

## Candidate artifacts and release boundary

Prepare a local AltStore candidate with `ios/scripts/package.sh`; it verifies the ad-hoc signature, IPA metadata and a before/after source fingerprint. AltStore supplies the user's final signing. Use the established installation identifier for an existing private test channel; keep the repository's official identifier unchanged. The candidate directory contains `release.json`, `source.json`, checksums and the IPA. Pair it with the verified frontend export and its `mobile-assets.json` manifest.

Before delivery, confirm the target server's backend version and the channel's installed/published build number. This local candidate does not authorize replacing the live frontend, pushing the experiment or publishing an AltStore release. Physical folding/rotation, keyboard, larger text, VoiceOver, in-place retention, offline reboot and subsequent sync remain open.
