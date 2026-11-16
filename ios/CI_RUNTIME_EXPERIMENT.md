# iOS CI runner-time experiment (2026-11-16)

This fork-only experiment started from `9d62c56c`, the published PR #443 commit that
includes the disposable-simulator restart and app-controls acknowledgement fixes.
That commit is eight commits ahead of the fetched `origin/main` (`a5977862`), which
lacks those fixes and the Duo navigation fixture. The experiment workflow accepts
only manual dispatches and has no release, Pages, or candidate artifact publication
jobs. Every run used one standard `xcode-27` macOS job with the full WebKit suite.

| Run | Change from published PR commit | Job time | WebKit step | Result |
| --- | --- | ---: | ---: | --- |
| [Upstream passing reference](https://github.com/AngeloSha/uchiyomi/actions/runs/43815293287) | None | 18m30s | 16m11s | 15 cases passed; 1 skipped |
| [Fork baseline](https://github.com/nVitius/uchiyomi/actions/runs/43824429607) (`407c59fb`) | Publication disabled only | 16m48s | 13m53s | Failed before any test case: simulator test-runner launch returned Mach error -308 |
| [No recovery reboot](https://github.com/nVitius/uchiyomi/actions/runs/43826401180) (`f4164a8d`) | Removed second simulator boot | 21m27s | 17m09s | Main group and Duo fixture passed; offline recovery fixture failed after WebKit froze and showed a blank page |
| [Serial Xcode testing](https://github.com/nVitius/uchiyomi/actions/runs/43829181072) (`47ffa13a`) | Restored reboot; added `-parallel-testing-enabled NO` | 24m43s | 22m40s | 15 cases passed; 1 skipped |

The three fork jobs consumed **62m58s of total runner time**. The upstream reference
is shown for context and is not included in that sum. The failed fork baseline
cannot establish a successful before-time on the same fork.

## Timing observations

- The upstream passing run reached its first WebKit `xcodebuild` invocation about
  8m13s after the WebKit step began: 5m43s to the second boot, then 2m26s more.
- The fork baseline took 5m03s to the second boot and another 3m41s to Xcode.
  The simulator service died while Xcode tried to launch the first test host.
- Without the second boot, the first boot alone took 8m34s. There was no measured
  startup saving, and the offline recovery case failed after repeated WebContent
  freezer errors and a timed-out page-content wait.
- With serial Xcode testing, the two boot phases still consumed about 8m24s.
  The first Xcode invocation ran from 08:21:17 to 08:29:38 UTC; the selected
  tests ran from 08:24:37 to 08:26:34. Thus test-host setup and teardown, not
  just test assertions, dominated that invocation. Later fixtures still ran
  in separate hosts, and the complete job was 6m13s slower than the upstream
  passing reference.

## Decisions

The two runtime changes were reverted on this experiment branch. Neither showed
a safe runner-minute reduction. Keep the full release suite and the separate
WebKit/cache/authentication hosts; combining them previously caused lifecycle
stalls. Do not replace a failure with longer timeouts or automatic assertion
retries.

The production workflow can reduce *wasted* runner minutes from superseded PR
runs by changing only its concurrency expression to:

```yaml
cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

This leaves tag/release publication serialized and non-cancelled. The expression
is linted on this experiment branch, but no superseded-PR cancellation was
measured here. It should be applied separately to the production workflow after
review, without copying the experiment's manual-only trigger or removed
publication jobs. Frontend dependency caching is lower priority: its step took
25–49 seconds in these runs, while WebKit consumed 13–23 minutes.
