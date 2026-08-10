# Camera effects on Android — the power path

What `XCameraEffects` costs a phone in draw and heat, where that cost lands in
the pipeline, and which of the two candidate reductions — a GLES compositor, an
adaptive rate — this package takes.

Paths are anchored at the `ux` package root. The ownership model this design is
scoped against is the `XCameraEffects` row of
[docs/architecture.md](architecture.md): the host owns the camera and the track,
the core owns the composite and the buffers it renders into, and pixels are
given up only by closing a frame. Nothing here moves those boundaries.

Every number carries its basis:

* **[measured]** — a value in the recorded ladder below.
* **[code]** — derived by reading the pipeline sources, not observed.
* **[assumed]** — neither; a stated premise the decision rests on.

---

## The measurement

Pixel 7 Pro, in-call against an emulator peer, 240 s per rung, one trial, each
rung admitted at a 30.5 C skin ceiling. Harness: babylon
`tools/effects-thermal-bench.mjs`. Each rung adds one layer of the pipeline to
the one below it: `baseline` attaches no processor, `passthrough` attaches one
that crosses the bridge and copies, `mask-only` adds the segmenter and ignores
what it publishes, `dim` runs the whole path.

| rung | CPU proxy | Δcpu | avg mA | ΔmA | C/min | ΔC/min | peak C | thermal | fps |
|---|---|---|---|---|---|---|---|---|---|
| baseline | 51.5 | — | 5 | — | 0.72 | — | 58.0 | 0 | 24.3 |
| passthrough | 52.6 | +1.1±0.3 | 3 | −2±2 | 0.87 | +0.15±0.03 | 56.0 | 0 | 24.1 |
| mask-only | 56.0 | +3.4±0.3 | 15 | +13±5 | 1.08 | +0.20±0.05 | 64.0 | 0 | 24.4 |
| dim | 53.8 | −2.2±0.2 | 52 | +37±10 | 1.41 | +0.34±0.06 | 78.0 | 0→1 | 24.3 |

Δ is against the rung above. The peak sits on the `BIG` zone at every rung.

Four limits bound what the table can carry:

1. **The mA column is a residual, not a meter.** The driver runs on AC with the
   pack near float, so `current_now` reads only the draw the charger does not
   cover. The `passthrough` rung reads −2±2 mA while every thermal zone's slope
   rises 0.26–0.36 C/min — a rung that heats faster and draws no more current is
   the charger absorbing the difference, not a free stage. **[measured]**
2. **The skin slope is the better-behaved energy proxy** and is what this design
   attributes with: it is monotone across the ladder, its standard error comes
   from a least-squares fit over 48 intervals, and it moves at the rung where mA
   is pinned to the floor.
3. **The ladder carries no drift rung, so every delta carries unpriced drift.**
   It is ordered in time and each rung starts hotter than its admission floor
   (`dim` starts 0.8 C above `baseline`). Drift accumulates in ladder order, so
   later rungs are over-attributed: the composite's share below is an upper
   bound.
4. **Blur carries no measurement on this ladder**, and one trial per rung gives
   no across-trial variance.

Within-rung series exist only for `baseline`, where CPU busy drifts +1.0pp
over the window as `BIG` warms 46 → 50 C. A fixed workload therefore reads
*higher* on the proxy as the die warms, which is the opposite sign to the `dim`
rung's drop. **[measured]**

---

## Cost attribution

### By slope, the three stages are comparable

| stage | ΔC/min | share of the composited path's added heat |
|---|---|---|
| bridge crossing + I420 materialization + copy | +0.15±0.03 | 22% |
| mask producer | +0.20±0.05 | 29% |
| effect render + person blend | +0.34±0.06 | 49% |

Total added heat over a bare call is +0.69 C/min. **[measured]** By the mA
column the same three stages read −5%, 27% and 78%; the disagreement is limit 1,
and the slope split is the one this design uses.

The consequence is that **no single stage owns the cost.** Removing the
composite render entirely leaves 51% of the added heat in place.

### Where the render's work is

`CameraEffectCompositor.render` runs five full-resolution passes per frame for
`DIM` at 1280x720 I420 (1.38 MB/frame): **[code]**

1. `RenderScratch.readInput` — three `copyPlane` loops pull the planes row by
   row out of the host's `ByteBuffer` into heap `ByteArray`s.
2. `dim` — per-pixel multiply-and-shift over Y, U and V, source arrays to
   destination arrays.
3. `prepareMask` — the mask grid's 144 rows stretched to the frame's width,
   two `FloatBuffer.get` calls per output sample: 184k samples per frame.
4. `blendPerson` — `blendLuma` reads `inY` and `outY` and rewrites `outY` with a
   per-pixel interpolation between two mask rows, accumulating the background
   grid; `blendChroma` does the same over both chroma planes.
5. `writeInto` — the three destination arrays copied into the output buffer's
   direct `ByteBuffer`s.

That is roughly 8 MB of memory traffic and 2.6M per-pixel operations per frame,
190 MB/s and 62M ops/s at 24 fps. The `NONE` compositor the `passthrough` and
`mask-only` rungs run does passes 1, 5 and a bulk `copyInput` — about 5.5 MB per
frame and no per-pixel arithmetic. The render's measured +0.34 C/min therefore
buys ~2.5 MB/frame of extra traffic and the arithmetic on top of it. **[code]**

The intermediates are what the traffic is made of. `inY`/`outY` exist so that
`dim` can write a background the blend then reads back; a single pass computing
`(person·α + dim(source)·(256−α)) >> 8` straight from `planes.dataY` into the
output buffer carries the same arithmetic over ~2.8 MB/frame. **[code]**

### Where the mask producer's work is

`PersonMaskProducer.consider` runs on the frame-delivery thread for every frame
and self-gates: `claim()` refuses while an inference is in flight or while the
cadence interval has not elapsed. A frame that passes the gate pays `copy` —
a nested `ByteBuffer.get`/`put` downscale of the full-resolution planes into a
256x144 NV21 input, 37k luma samples plus 18k chroma — and then ML Kit's own
inference. **[code]** The measured +0.20 C/min is both together at up to 15
submissions per second. The zone split says which is which: from `passthrough`
to `mask-only` the `TPU` and `G3D` slopes rise (+0.13, +0.11) while `BIG` falls
(−0.28) and `LITTLE` is flat. Inference lands off the CPU clusters.
**[measured]**

### The CPU proxy drops because it measures occupancy

The proxy is `head -1 /proc/stat`: busy jiffies over total jiffies, summed
across all eight cores, system-wide. It counts *where a core was scheduled*, not
work and not energy, and on a heterogeneous DVFS part those come apart. Two
mechanisms move it down while the render adds work, and both are needed to
cover the −2.2pp:

* **Frequency and placement.** Raising the delivery thread's per-frame work
  raises its utilization signal, which raises the frequency schedutil picks and,
  past the migration threshold, moves it to a larger cluster. The same work then
  occupies fewer jiffies — for that thread and for everything sharing the
  cluster whose frequency it raised. A jiffy-based busy fraction falls while
  energy rises. **[assumed]** — nothing in the artifacts records per-core
  residency or time-in-state.
* **The mask cadence backs off under load.** `PersonMaskProducer.complete`
  widens the submission interval to the last observed inference latency
  (`interval = max(66.7 ms, latency)`). A hotter, busier SoC raises ML Kit's
  latency past 66.7 ms, the interval widens, and submissions per second fall —
  removing the per-frame `copy` and the inference CPU that the `mask-only` rung
  spends in full. The `mask-only` rung prices that whole term at +3.4pp, so a
  cadence that halves gives back ~1.7pp. **[code]** for the mechanism,
  **[assumed]** for it firing at the `dim` rung; the realized cadence is not in
  the artifacts.

Thermal mitigation is not a third mechanism: `dim` is the only rung to reach
status 1, and a frequency cap raises a busy fraction rather than lowering it.
**[measured]** that the transition happens, **[code]** that its sign is wrong
for this observation.

The published rate holds at 24.3 fps across every rung, so none of this is the
pipeline dropping frames. **[measured]**

### What the zone slopes do not say

At the `dim` rung `G3D` (+0.82 C/min against `mask-only`) and `TPU` (+0.78) rise
faster than any CPU cluster, and the composite issues no GPU or accelerator call
anywhere in `CameraEffectCompositor`. **[code]** Two readings fit, and the
evidence does not separate them:

* the zones are die-area sensors adjacent to the CPU complex, reporting spread
  heat from an entirely CPU-side change; **[assumed]**
* the composited content changes downstream GPU cost — the encoder's input
  conversion and the local preview's upload both scale with what the frames
  contain, and a mask edge refreshed at up to 15 Hz against a 24 fps stream is
  new residual energy every frame. **[assumed]**

The second is the one that matters for the decision, because it is the only cost
a GLES compositor would *not* remove. Separating them is a named prerequisite
below.

### Blur

Blur's render has the same shape as dim's: one read of each source plane, one
full-resolution write, then the same blend. What it adds over dim is the 1/8
grid work — three box-pass pairs on a 160x90 grid — plus `stretchRow` over 90
rows per plane and a vertical lerp that reads an `IntArray` row buffer instead
of multiplying a byte. That is on the order of one extra full-resolution pass,
not a different order of cost. **[code]**

The `dim` rung is therefore a usable lower bound for blur, and the harness's
framing of dim as the cheap composite and blur as the expensive one does not
hold against the current sources. A weaker-methodology measurement puts blur at ~+17pp
CPU over a bare call with recurring light throttle; it is not comparable to this
ladder and is carried only as a sign, not a magnitude.

---

## The GLES path

### What moves

The compositor's five CPU passes become one fragment shader over the camera
texture: sample the source, apply dim or a separable blur, blend against the
mask sampled as a texture, render to an output texture the publication wraps.
The mask producer's full-resolution `copy` becomes a 256x144 downscale rendered
into a small FBO and read back — 147 KB per submission at up to 15/s, against
the current full-resolution plane walk at 24 fps.

What does not move: ML Kit's inference itself, which is already off the CPU
clusters **[measured]**, and whatever share of the `dim` rung's `G3D` rise is
downstream encoder and preview cost rather than spread heat.

### Projected effect

Bounded by the measured rungs: the crossing (+0.15) and the render (+0.34) are
71% of the composited path's added heat, and both are what the GPU path
replaces. The saving is bounded above by 0.49 C/min and by ~47 mA, and below by
nothing the evidence prices — the residual GPU cost of the shader is unmeasured,
and the zone that already rises fastest at the `dim` rung is `G3D`. A projection
of a specific saving inside that interval has no basis and this design does not
make one.

### Implementation scope

* **Bridge representation.** `CameraTrackBridging` transfers a `CameraFrame`
  whose `planes()` are CPU I420 and takes back a `PublishedFrame` over the
  core's own planes. A GPU path needs both widened to a texture representation
  carrying a texture name, its transform, and a sync fence, plus the host's
  shared `EGLContext`. The transfer verbs and the release rules are unchanged —
  the host still owns capture and release, the core still owns what it renders
  into — so this widens the representation without moving the boundary.
* **Context lifetime against the frame-processor threading.**
  `LocalVideoTrack.ExternalVideoFrameProcessing.onFrame` runs on the capturer's
  handler thread; `CameraEffectsService` attaches and detaches from Flutter's
  thread. GL setup therefore happens lazily on the first frame and teardown on
  `retire()`, which is not the thread that called it. A context outliving a
  camera restart is a leak the current CPU path cannot have.
* **The background grid.** `CameraBackgroundGrid` is accumulated inside
  `blendLumaRow` as a by-product of the CPU blend, and `CameraCompositeRecord`
  carries it to `CameraEffectsRig.composites()`. babylon's
  `phone-effects-band.mjs` and `phone-effects-report.mjs` calibrate on it. A GPU
  blend must produce the same 16x16 reduction on the GPU and read it back, or
  the frozen rig contracts lose their input.

### Regression risk

* `CameraEffectCompositorOutputTest` pins eight scenes by CRC32 over the
  composite's Y, U and V bytes. A GPU render does not reproduce them. Replacing
  them with a tolerance comparison weakens the contract that pins the look, and
  keeping both paths to keep both pins is the migration fallback this repository
  does not take.
* `CameraEffectCompositorBenchmark` measures composite latency on the JVM
  against a 12 ms mean and 24 ms p99 budget. There is no GPU on that host, so
  the whole on-host verification surface for the compositor disappears with the
  CPU path.
* The `phone-effects-rig` calibration depends on the background grid above.

---

## Adaptive rate

### Knobs

| knob | what it changes | measured anchor | what it costs the user |
|---|---|---|---|
| mask cadence | `PersonMaskProducer.TARGET_SUBMISSIONS_PER_SECOND`, 15 | ≤0.20 C/min, the whole producer rung; the inference share scales with cadence, the per-frame gate check does not | the silhouette trails motion; already a named rig verdict (`mask-stale`) |
| blend resolution | `blendLuma` on a half-res luma grid with α upscaled | none | a softer silhouette edge, ~2 px |
| effect grid | `LUMA_DOWNSCALE` above 8 for blur | none | a coarser blur, no change to dim, which has no grid |
| published resolution | the track's capture format | none | not this package's — the host owns the format, so this is a request to the host, not a knob here |
| retract to none | publish the frame unchanged | the full +0.69 C/min | the effect disappears without the user asking, and `status` is the processor's account of the frames — an autonomous retraction has no authored `idle` behind it and contradicts the contract as written |

The first three land inside the existing ownership boundary. The last two do
not, and this design does not take them.

### Trigger

`PowerManager.addThermalStatusListener` (API 29) is the trigger. Under this
evidence it is specific: `dim` is the only rung to reach status 1, and it does
so inside a 240 s window, while `baseline`, `passthrough` and `mask-only` never
leave 0. **[measured]** `getThermalHeadroom` (API 30) forecasts ahead of
mitigation rather than reporting it, and is the better trigger where it exists;
it is unmeasured on this ladder. A slope trigger computed in-process needs a
temperature source the app does not have — `HardwarePropertiesManager` is
privileged — so it reduces to headroom.

`minSdk` is 21, so both are version-gated and hosts below API 29 hold the fixed
rates.

### Projected effect

Halving the mask cadence gives back at most half of +0.20 C/min. Halving the
blend's luma resolution gives back a share of +0.34 C/min that the evidence does
not split out. Together they are bounded above by ~0.27 C/min of the composited
path's +0.69, and they do not stop the path from heating — they change the slope
at which it does. **[measured]** for the bounds, **[code]** for the split.

---

## Decision

| path | measured cost it addresses | implementation cost | contract risk | provable without the thermal ladder |
|---|---|---|---|---|
| fuse the CPU render's passes | the render's +0.34 C/min (49%) | one file, no API change | none — the fusion is byte-identical by construction | yes |
| adaptive rate | the producer's +0.20 (29%) and part of the render | producer, a thermal source, a policy; gated at API 29 | none for the three knobs taken | partly |
| GLES compositor | the crossing and the render, +0.49 (71%) | new bridge representation, EGL lifetime across two threads, a GPU background-grid reduction | breaks eight byte pins, the JVM benchmark, and the rig's calibration input | no |

**Inside plan 701: the fused CPU render and thermal-triggered adaptive rate.**
Both stay inside the ownership model, both keep the byte pins, and both are
verifiable without reopening the thermal ladder. The fused render goes first: it
is the cheapest change against the largest measured stage, and its outcome
decides whether the GPU path has a cost left to remove.

**A later stream: the GLES compositor.** Its precondition is a per-block
measurement that says whether the `dim` rung's `G3D` rise is spread heat or real
downstream GPU cost — a GPU path that removes CPU arithmetic does not help
against the second, and the fused render may take the first below the threshold
where the migration is worth its contract cost.

**Not taken: published-resolution adaptation** (outside this package's
ownership) **and autonomous retraction to none** (contradicts the status
contract).

---

## Verification

Nothing here assumes the thermal ladder reopens.

| claim | what proves it |
|---|---|
| the fused render does strictly less work | `CameraEffectCompositorBenchmark` mean and p99 at 1280x720, against the standing 12 ms / 24 ms budgets |
| the fusion changes no pixel | `CameraEffectCompositorOutputTest`, all eight CRC32 scenes unchanged |
| the mask cadence backs off under load | `CameraEffectsRig.composites()` over a held call: distinct `maskFrameTimestampNs` values per second is the realized submission rate, per stage, through babylon's `phone-effects-rig.mjs` — the composite log, not the ladder |
| the adaptive trigger fires where the evidence says | the same log across a held `dim` call, against `PowerManager`'s status stream |
| the `G3D` rise is spread heat or downstream cost | GPU busy from the device's devfreq node beside WebRTC's own `encodeTime`, `qp` and `targetBitrate` for the same call, at the `mask-only` and `dim` stages |

A latency reduction is not an energy measurement. The step from "less work and
less traffic" to "less draw and a lower slope" is **[assumed]** until a rung
prices it, and the measurement that would is a two-rung A/B — fused against
unfused, same device, same call — sampling `BATTERY_PROPERTY_CURRENT_NOW`
in-process. That is a fraction of the ladder's harness and does not depend on
it.
