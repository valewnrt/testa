# Commands

Every command is `testa <command> [args]`. Target a specific simulator with
`--udid <udid>`; otherwise Testa uses the booted one. `testa help` prints the
same reference.

## Selectors

Most commands take a selector (`sel`):

| Form | Example | Matches |
|---|---|---|
| `eN` | `e5` | the element with that ref in the last `ui` snapshot |
| `#identifier` | `#save` | `accessibilityIdentifier` / React Native `testID` |
| `"label"` | `"Continue"` | label, value or visible text (case-insensitive substring) |
| `x y` | `120 300` | a point, in the same coordinates `ui` reports |

`tap`, `find`, `assert` and `wait` fall back to on-device OCR when the
accessibility tree has no match, and say which source answered:
`PASS exists (ocr) "Settings" @200,703`. Pass `--ocr` to skip the tree entirely.

## The loop

1. **Observe:** `testa ui` (on-screen elements), `testa see` (OCR every visible
   text), `testa find <q>`, `testa scrollto <sel>`.
2. **Act:** `tap`, `typein`, `setvalue`, `clear`, `swipe`, `drag`, `dragdrop`,
   `pinch`, `rotate`, `keycombo`, `button`. The reply ends with the settled UI
   diff (`-- ui changes --`), so no follow-up `ui` is needed.
3. **Verify:** `testa assert <sel> [exists|gone|value=…|label=…]` exits 0 or 1;
   `testa wait <sel> [gone] [timeoutMs]` blocks until it holds.
4. **Keep it:** `testa flow record save smoke.flow`. See [Flows & CI](flows-and-ci.md).

```text
$ testa ui
19 elements (on screen)
e1 Application "Testa Native" @201,437
e2 StaticText "ready" #status @201,89
e5 Button "Tap me" #tapButton @102,171
e18 TextField #textInput =type here @201,601
…

$ testa tap "#tapButton"
tapped e5 Button Tap me
-- ui changes --
~ e2 StaticText "tap:1" #status @201,89
~ e6 StaticText "count: 1" #tapCount @41,208

$ testa pinch "#pinchBox" 2.0
pinched
-- ui changes --
~ e2 StaticText "pinched:2.00" #status @201,89

$ testa assert "#status" label=pinched:2.00
PASS label pinched:2.00
```

## Reference

```
Observe
  ui [diff|full]            on-screen snapshot (diff = changes, full = incl. off-screen)
  see                       OCR every visible text + tap coords (any app)
  find <query> [--ocr]      elements matching label/id/value/role (OCR fallback)
  scrollto <sel>            scroll until an element is visible (vertical or horizontal)
  assert <sel> [exists|gone|value=..|label=..] [--ocr]
  wait <sel> [gone] [timeoutMs] [--ocr]  wait until it appears — or disappears
  audit                     accessibility audit (labels, 44pt targets, dupes)
  vdiff <baseline.png> [tolerancePct]   visual regression, OCR-aware
  screenshot [path.png]

Act   (sel = eN ref · #identifier · "label"; tap falls back to OCR text)
  tap <sel> | tap <x> <y> | tapocr <text>
  typein <sel> <text> | type <text> | setvalue <sel> <text> | clear <sel>
  key <hidUsage> | keycombo <cmd+shift+a> | button <home|lock|siri|apple-pay>
  swipe|drag|dragdrop <x1 y1 x2 y2> [secs]   (also <fromSel> <toSel>)
  longpress <sel | x y> [secs] | pinch <sel | x y> <scale> | rotate <sel | x y> <radians>

App / device
  devices | boot <udid|name> | shutdown <udid|all>
  install <app> | terminate <bundle> | apps | open <url>
  launch <bundle> [--env K=V ...] [--args <a> ...]
  logs [bundle] [seconds] | crashes [bundle]
  permission <grant|revoke|reset> <service> <bundle>
  record <start [path] | stop>

Environment
  push <bundle> <file.json | '{"aps":{"alert":"hi"}}'>
  location <lat> <lon> | location clear
  statusbar time 9:41 [battery 100 charged] [wifi 3] [cell 4] | statusbar clear
  appearance <dark|light> | contentsize <size|increment|decrement>
  locale <en_US> [lang]     (apps need a relaunch to pick it up)
  addmedia <file...> | pbcopy <text> | pbpaste
  biometry <enroll|unenroll|match|nomatch>

Flows / CI   (deterministic replay — no agent, no tokens)
  flow run <file.flow ...> [--junit <out.xml>] [--artifacts <dir>] [--quiet]
  flow record start                          mark "record from here"
  flow record save <file.flow> [--all]       write what you just did as a flow
  matrix "<dev1,dev2,…>" -- flow run <file.flow ...>

Setup / daemon
  setup | start | stop | status | info | version | layout | mcp
```

## Quality gates

- **`testa audit`** lists missing labels, tap targets under 44 pt, duplicate
  labels and id-shaped labels. Missing labels are errors and make it exit
  non-zero, so it can fail a flow or a CI job; the rest are warnings. It is a static check: it cannot tell you whether a label is
  *good*.
- **`testa vdiff <baseline.png>`** compares the current screen with a baseline
  using an antialiasing-tolerant pixel diff, writes a red heatmap, and adds
  OCR-aware `- lost:` / `+ new:` lines, so "3.2 % changed" becomes "the
  *Checkout* button is gone". It compares equal-sized images only; baselines
  are per device.
