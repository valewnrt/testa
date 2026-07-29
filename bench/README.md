# Token benchmark

How many tokens does one step of an agent-driven E2E run actually cost?

`bench.sh` measures **Testa against itself** on a real booted simulator. It does
not measure any other tool. Where this page contrasts Testa with
"screenshot-based approaches", it means *the general shape of an agent that
uploads a screenshot each step* — the image cost is computed from Testa's own
screenshot, not copied from someone else's benchmark.

```bash
swift build -c release
testa boot "iPhone 17 Pro"          # any booted sim; any app in the foreground
bench/bench.sh                      # bench/bench.sh 20  for 20 timing runs
```

## Method

For whatever is on screen right now, the script captures four things and
reports bytes, approximate tokens, and best-of-N wall clock:

| what | how |
|---|---|
| `ui` | the accessibility snapshot an agent reads each step |
| `ui diff` | the incremental snapshot — what every acting command now appends for free |
| `see` | on-device Vision OCR of every visible text region |
| `screenshot` | PNG on disk, plus its base64 encoding |

Token conversion:

- **Text** — `ceil(chars / 4)`. The usual rule of thumb. Real BPE counts vary by
  a few percent; the ratios below are far too large for that to matter.
- **Images, upper bound** — `ceil(base64 chars / 4)`. This is what an image costs
  if it is pasted into the prompt as text.
- **Images, native vision** — providers with a real vision encoder charge much
  less, and **every provider counts differently**. Rather than invent a universal
  number, the script prints one *worked, labelled* example: cap the long edge at
  1568 px, then `(w × h) / 750`. Swap in your own provider's formula; the script
  prints the raw pixel dimensions so you can.

Timing is **best-of-N**, not mean: the floor is the reproducible number, the tail
is whatever else the machine was doing. `testa info` is timed as a near-no-op to
separate fixed CLI overhead (process spawn + dyld + socket connect) from the
marginal cost of actually reading the screen.

## Results

Real run, `2026-07-29`, Apple silicon, Xcode 26.4 / iOS 26.4, **iPhone 14 Pro**
simulator (1179×2556 px), showing the native SwiftUI showcase
(`examples/native`) — 19 on-screen accessibility elements. `testa 0.2.0` release
build, 5 timing runs.

| mode | bytes | ~tokens | best ms |
|---|---:|---:|---:|
| `ui` | 809 | **203** | 326 |
| `ui diff` (unchanged screen) | 12 | 3 | 333 |
| `see` (OCR) | 240 | 60 | 382 |
| `screenshot` (PNG on disk) | 154,026 | — | 318 |
| ↳ base64, pasted as text | 205,368 | **51,342** | — |
| ↳ same PNG, native vision encoder¹ | — | **~1,512** | — |

<sub>¹ 1179×2556 resized to a 1568 px long edge → 723×1568, then `(w×h)/750`. One
worked example of one provider's formula — yours will differ.</sub>

### testa `ui` per step vs. a screenshot per step

| steps | `ui` each step | screenshot each step (native vision) | screenshot each step (base64) |
|---:|---:|---:|---:|
| 10 | 2,030 tok | ~15,100 tok | 513,420 tok |
| 50 | 10,150 tok | ~75,600 tok | 2,567,100 tok |

**~7× cheaper** than a screenshot on a native vision encoder, **~253× cheaper**
than a base64 image — per step, before counting that `ui` is also *precise*
(tap-ready coordinates, stable ids) where a screenshot is a guess.

Two things make the real-world gap larger than the table:

- **Acting commands already return the diff.** In 0.2.0 every mutating command
  appends `-- ui changes --` to its reply, so the common loop is *act → read the
  diff*, not *act → full snapshot*. The diff on an unchanged screen costs 3
  tokens; after a real tap it carries only what moved.
- **Flows cost zero.** Once a run is saved with `testa flow record save`,
  `testa flow run` replays it deterministically with **no model in the loop at
  all** — the regression suite's marginal token cost is 0.

### Latency

```
fixed CLI overhead (testa info, a near-no-op):  ~300 ms
marginal cost of a warm ui snapshot:            ~25 ms   (24–39 ms across runs)
```

The ~300 ms is process spawn + dyld + socket connect, paid once per `testa …`
shell invocation. **An MCP client does not pay it**: the server process stays up
and each tool call is a socket round trip, so the per-call cost is the marginal
one. That is the basis for the "~60 ms warm snapshot" figure quoted in the
README — measured here at 24–39 ms marginal on this machine, comfortably inside
it. Cold start (first call of a session, which boots the daemon and warms the
accessibility translator) is several seconds, once.

## Caveats

- One screen of one app. A denser screen makes `ui` bigger; the screenshot cost
  is fixed by resolution, so the ratio *grows* on simple screens and shrinks on
  dense ones. Run `bench.sh` on your own app.
- `ui` reports on-screen elements only. `ui full` (off-screen included) is
  larger; that is the point of the default.
- Screenshot bytes depend on screen content — PNG compresses flat UI well.
- These are Testa's numbers only. No competitor was benchmarked, and none is
  claimed here.
