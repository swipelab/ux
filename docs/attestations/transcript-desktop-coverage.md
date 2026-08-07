# Transcript desktop coverage attestation

Every invariant the screen-source picker and the camera background effects
carry, and the artifact that proves it. Each invariant has two artifacts: a
deterministic one that runs in a suite, and a live one that runs against a real
host.

File paths are anchored at their repository root — `apps/app/…` is the consumer
app, everything else is `ux`. A cell holds exactly one of:

* `<file path>::<test case name>` — a deterministic artifact;
* `<rig entry point> — <run date>` — a live artifact;
* `NOT RUN — <reason> — <owner>`;
* `GAP — <what is missing>`.

## Invariants

| Invariant | Deterministic | Live |
|---|---|---|
| A source's thumbnail is nullable, and a capture fails wholesale only when nothing rendered | `darwin/ux/Tests/ux_macos_coreTests/ScreenSourceLoaderTests.swift::testOneFailingSourceKeepsTheRestAndSucceeds` | `example/integration_test/screen_sources_test.dart — 2026-08-07` |
| Every returned id is in the primed capture cache | `apps/app/test/screen_share_sources_test.dart::the primed ids are the allowed ids, whole and unchanged` | `example/integration_test/screen_sources_test.dart — 2026-08-07` |
| Permission is not guessed from content | `darwin/ux/Tests/ux_macos_coreTests/ScreenSourcesServiceTests.swift::testListWithoutTheGrantIsDeniedWithoutPromptOrEnumeration` | `NOT RUN — no rig drives a denial and a relaunch; the picker rig reads the grant once and stops on its absence — the plan` |
| Vision never blocks the WebRTC delivery lock | `darwin/ux/Tests/ux_macos_coreTests/PersonMaskProducerTests.swift::testFrameCallbacksCompleteWhileAnInferenceNeverAnswers` | `NOT RUN — the app queries no WebRTC stats, and the composite interval is an os_signpost that needs Instruments — the plan` |
| Non-none never leaks raw after a command completes | `darwin/ux/Tests/ux_macos_coreTests/CameraEffectCompositorTests.swift::testTheProcessingSeamPublishesTheOutcomesFrameAndNeverRaw` | `NOT RUN — the effects service captures its backend at construction and exposes no fault seam, so the injected-failure half of the sequence has no run — apps/app/test/camera_effects_test.dart` |
| One current track owns one processor | `darwin/ux/Tests/ux_macos_coreTests/CameraEffectsServiceTests.swift::testASecondTrackDetachesTheFirstByIdentityAndAttachesTheSecond` | `dev-smoke --effects — 2026-08-07` |
| Blur and dim share one correct compositor | `darwin/ux/Tests/ux_macos_coreTests/CameraEffectCompositorTests.swift::testABlurCompositeKeepsThePersonAndChangesTheBackground` | `NOT RUN — the wire peer is a signalling client with no decoder, and a hands-off gate has no eyeball — the plan` |
| A composite holds the frame budget | `darwin/ux/Tests/ux_macos_coreTests/CameraEffectCompositorBenchmarks.swift::testBlurWithAMaskLatency` | `NOT RUN — nothing measures composite latency on a live camera — the plan` |
| A window id that goes stale is invalidated on the failure paths | `apps/app/test/screen_share_sources_test.dart::a capture start holding a superseded snapshot re-selects from the newest one` | `NOT RUN — no rig closes a window between the snapshot and the capture start — the plan` |
| NV12 and BGRA inputs are converted explicitly | `darwin/ux/Tests/ux_macos_coreTests/CameraEffectCompositorTests.swift::testEveryInputFormatComposites` | `NOT RUN — a host camera hands the rig one pixel format, so no live run covers both — the plan` |
| The 256x144 downscale copy is synchronous and releases the camera buffer | `darwin/ux/Tests/ux_macos_coreTests/PersonMaskProducerTests.swift::testTheCameraBufferIsReleasedWhileTheCopyReachesTheInference` | `NOT RUN — pool starvation under a live camera needs an allocation trace the rig does not take — the plan` |

The budget rule is a release median at or under 4 ms at 1920x1080. The
benchmark's four cases report and assert nothing about time; their worst
release median is 1.154 ms, blur with a mask. A debug build of the same suite
reports a multiple of that and is not the measurement the rule reads.

## Residuals of the effects rig

What a green `dev-smoke --effects` run leaves unmeasured, with the reason and
the owner the rig records.

| Row | Reason | Owner |
|---|---|---|
| blur and dim look right at the pixel level | the wire peer is a signalling client with no decoder, and a hands-off gate has no eyeball | the plan |
| a fault after activation turns the camera off and drops the request | the effects service captures its backend at construction and exposes no fault seam | `apps/app/test/camera_effects_test.dart` |
| a host without an effect processor classifies as env | the effects service returns normally when the host is unavailable, so this run cannot see it | the plan |
| the matrix on an Intel host | no Intel host is reachable from this run | the plan |
| energy and thermal pressure across ten minutes of effected capture | powermetrics needs superuser, and sudo -n fails on this host | the plan |
| published frames per second and the composite interval per frame | the app queries no WebRTC stats, and the composite interval is an os_signpost that needs Instruments | the plan |
| a camera flip keeps the requested effect | the flip resolves through a position lookup that falls back to the default device, and a Continuity Camera makes the choice differ between runs | the plan |
| the profile table that gates which hosts run effects | the profile gate lives natively in ux's `available()`, not in this rig | the plan |
