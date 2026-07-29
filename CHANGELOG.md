# Changelog

All notable changes to Testa are documented here. Format roughly follows
[Keep a Changelog](https://keepachangelog.com/); versions are git tags.

## [0.2.0] — 2026-07-29

The "runs without an agent" release. Testa still drives a simulator for an LLM,
but a run can now be **recorded once and replayed forever with zero tokens** —
plus a large environment-control surface, an accessibility audit, visual
regression, and a hardening pass on everything that reads app-authored text.

Version is now single-sourced from `Sources/testa/Version.swift`; `testa version`
reports it, as does the MCP `serverInfo`.

### Security / robustness
- **Prompt-injection hardening.** Accessibility labels, values and OCR text are
  escaped and truncated in snapshots (`"` → `\"`, newlines → `\n`, long strings
  → `…`), so a crafted string in the app under test cannot forge extra element
  lines. Escaping preserves *shape*, not trustworthiness — the skill and the MCP
  tool descriptions now say explicitly that screen text is data, never
  instructions.
- **MCP tool descriptions carry an untrusted-text warning** on every tool that
  returns app-authored text.
- Socket read/write **timeouts** on both ends, so neither the CLI nor the daemon
  can hang forever on a wedged peer.
- `SIGPIPE` ignored — writing to a closed socket surfaces as `EPIPE` instead of
  killing the process.
- **Daemon spawn lock**: concurrent first calls can no longer race into two
  daemons for the same UDID.
- **Line caps** on socket and stdin framing (10 MiB), so a runaway peer cannot
  exhaust memory; oversized lines are discarded, not buffered.
- **Path guards on every file Testa writes** (screenshots, recordings, baselines,
  diffs, JUnit, artifacts): paths are standardized and validated before use.
- **Clamped durations** on gestures and waits — a bogus number can no longer park
  the daemon for an hour.
- **Deadlines on the accessibility walk**, so a pathological tree degrades to a
  partial snapshot instead of hanging.

### UX
- **Every mutating command now appends the settled UI diff to its reply**
  (`-- ui changes --`). The common agent loop is act → read the diff; a follow-up
  `ui` is usually unnecessary. Reflected in the MCP tool descriptions too.
- **Typing covers full ASCII**, including brackets and pipe. Text that is not
  HID-typeable (umlauts, emoji, `π`) **automatically falls back to pasteboard +
  Cmd-V**, so `type`/`typein` work with any string.
- `wait <sel> [gone] [timeoutMs]` — wait for an element to appear *or* disappear.
- `assert` accepts values containing spaces (`assert #s "label=dropped on zoneB"`).
- **Fuzzy OCR matching** (Levenshtein) — `tapocr "Settings"` still hits when OCR
  reads `Setting5`.
- `scrollto` handles **horizontal** scrolling, not just vertical.
- `testa version`.

### Environment
A device-state suite, all through public `simctl` APIs unless noted:
- `push <bundle> <file.json | inline JSON>` — deliver an APNs payload.
- `location <lat> <lon>` · `location clear`.
- `statusbar time 9:41 [battery 100 charged] [wifi 3] [cell 4]` · `statusbar clear`
  — deterministic screenshots.
- `appearance dark|light`.
- `contentsize <size|increment|decrement>` — Dynamic Type.
- `locale <id> [lang]` — best-effort; **apps need a relaunch to pick it up**.
- `addmedia <paths…>` — add photos/videos to the simulator library.
- `pbcopy <text>` / `pbpaste` — simulator pasteboard.
- `launch <bundle> [--env K=V …] [--args …]`.
- `biometry enroll|unenroll|match|nomatch` — Face ID / Touch ID.
- `button home|lock|siri|apple-pay` — **real Indigo HID hardware-button events**,
  not a simctl shortcut.
- `keycombo cmd+a`, `ctrl+cmd+k`, … — hardware key combinations.

### Flows / CI
- **`testa flow run <file.flow …> [--junit x.xml] [--artifacts dir]`** —
  deterministic replay with no model in the loop. Exit 0 iff every step passed.
- **Plain-text `.flow` format**: one CLI command per line, `#` comments, and the
  directives `@name`, `@timeout`, `@require <bundle>`. There is nothing to learn
  beyond `testa help` — the lines *are* testa commands.
- **Failure artifact bundle**, captured at the moment of failure: `screenshot.png`,
  `ui-full.txt`, `see.txt`, `logs.txt`, `crashes.txt`, `summary.txt`.
- **`testa flow record start` / `testa flow record save <file.flow> [--all]`** —
  records what an agent actually did and writes it out as a flow, filtering pure
  reads (`--all` keeps them).
- **`testa matrix "iPhone 17 Pro,iPad Pro" -- flow run …`** — the same flow on
  every device, one warm daemon per UDID in parallel, merged JUnit, summary table.
- JUnit XML output for any CI that reads it.
- Committed example: `examples/native/smoke.flow`.

### Audit / visual regression
- **`testa audit`** — accessibility audit over the live tree: `missing-label`,
  `small-target` (`<24pt` error, `<44pt` warning), `duplicate-label`,
  `label-in-id-style`. Returns `ok:false` on errors, so it gates a CI job.
- **`testa vdiff <baseline.png> [tolerancePct]`** — visual regression. First run
  bootstraps the baseline; after that it does a downsampled, antialiasing-tolerant
  pixel diff, writes a red heatmap PNG, and adds **OCR-aware `- lost:` / `+ new:`
  text lines** so a percentage becomes a sentence. `PASS`/`FAIL` against the
  tolerance.

### MCP
- Server version 0.2.0.
- **Per-tool optional `udid`** — target a specific simulator from any tool.
- **Strict required-argument validation** with typed, actionable error messages
  instead of a confusing downstream failure.
- **13-tool token-lean default**; the full **40-tool** surface via
  `testa mcp --full` or `TESTA_MCP_FULL=1`. Fat servers burn context and confuse
  tool choice, so the device-state and exotic-gesture tools are opt-in.

### Distribution
- **`action.yml`** — composite GitHub Action: installs testa, boots a device,
  runs flows, uploads JUnit + failure artifacts.
- **`.github/workflows/xcode-beta.yml`** — weekly matrix over every Xcode on the
  runner (betas included): `swift build`, `swift test`, `testa layout` (the
  Indigo struct self-check), and the smoke flow. Day-zero warning when a new
  Xcode moves a private-framework field.
- **CI** now runs `swift test` and a real end-to-end job that builds the SwiftUI
  showcase and replays `smoke.flow`. All third-party actions are SHA-pinned.
- **`.claude-plugin/plugin.json` + `.mcp.json`** — the repo works as a Claude
  Code plugin / marketplace entry.
- **`server.json`** — MCP Registry manifest (`io.github.valewnrt/testa`).
- **`npm/` → `@valewnrt/testa-mcp`** — a thin `npx` launcher. It is macOS-only,
  has no dependencies, and **downloads nothing**: it locates an installed `testa`
  and execs `testa mcp`, or prints the Homebrew install instructions and exits 1.
- **`bench/`** — reproducible token benchmark with a documented method.
- Homebrew: the formula is now installed via a **tap**
  (`brew tap valewnrt/testa https://github.com/valewnrt/testa`). Homebrew has
  not accepted `brew install <raw formula URL>` since 2.x; the README instruction
  was broken and is fixed.

## [0.1.3] — 2026-05-22

### Added
- `testa logs [bundle] [seconds]` — recent app console output (via `simctl … log show`).
- `testa crashes [bundle]` — newest crash report for the app, if any.
  Both are independent, public-API implementations (no third-party tooling).

## [0.1.2] — 2026-05-22

### Fixed
- **Daemon failed to spawn when `testa` was run by bare name on `PATH`** (i.e.
  every Homebrew / installed setup). The executable path is now resolved via
  `_NSGetExecutablePath` instead of the unreliable `argv[0]`, so CLI commands
  and MCP tool calls work when installed, not just when run by relative path.

### Added
- README demo GIF + badges + an honest "Limitations" section.
- `CONTRIBUTING.md` and this `CHANGELOG.md`.

## [0.1.1] — 2026-05-22

### Added
- `testa setup` — one command installs the Claude Code skill and registers the
  MCP server. `install.sh` and the Homebrew formula now delegate to it, so
  `brew install testa` is fully one-shot.

## [0.1.0] — 2026-05-22

Initial release.

### Engine
- HID injection via the Indigo wire format (`SimDeviceLegacyHIDClient`): tap,
  long-press, swipe, drag-and-drop, pinch, rotate, multi-touch, keyboard.
- Accessibility tree via `AXPTranslator` with a token-delegate XPC bridge.
- In-process framebuffer screenshot (IOSurface → CGImage).
- On-device **Vision OCR** — tap visible text on any app, no `testID` needed.
- Universal text entry (`setvalue`, any unicode/emoji); SpringBoard remediation.

### Tooling
- Warm daemon over a `0600` per-user Unix socket; thin CLI; MCP server (`testa mcp`).
- Token-efficient snapshots (refs, viewport-only, `find`, `assert`, `ui diff`),
  `scrollto`, real auto-settle, daemon resilience, multi-simulator.
- App lifecycle (boot/install/launch/terminate/apps/open/permission), video record.
- Claude Code skill; Homebrew formula + tap; `install.sh`; CI; unit tests.
- Two showcase apps (SwiftUI + Expo/React Native) that double as the E2E suite.

Zero third-party runtime dependencies. Verified on Xcode 26.4 / iOS 26.4.
