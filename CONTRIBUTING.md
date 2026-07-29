# Contributing

Thanks for your interest in Testa!

## Dev setup

```bash
git clone https://github.com/valewnrt/testa && cd testa
make build      # debug build
make test       # unit tests (swift test)
```

Boot a simulator, then drive it: `./.build/debug/testa ui`.

## Layout

- `Sources/TestaEngine/` — Obj-C engine. Talks to Apple's private CoreSimulator /
  SimulatorKit / AccessibilityPlatformTranslation frameworks (HID injection,
  accessibility tree, screenshot, OCR). No third-party code.
- `Sources/TestaKit/` — pure, simulator-free screen model (unit-tested).
- `Sources/testa/` — daemon, CLI, MCP server, simctl wrapper.
- `examples/` — SwiftUI + Expo/React Native showcases that double as the E2E
  suite (`examples/*/e2e.sh`).
- `skills/testa/SKILL.md` — the Claude Code skill.

## Before a PR

- `make test` passes.
- `make e2e` passes against the native showcase (needs a booted sim).
- Keep the **zero third-party runtime dependency** rule: only Apple frameworks
  shipped with Xcode, plus `xcrun simctl`.
- Match the surrounding style; keep comments about *why*, not *what*.

## Releasing

`git tag -a vX.Y.Z`, push, then bump `url`/`sha256` in `Formula/testa.rb` (here
and in the `homebrew-testa` tap). `release.sh` builds a universal binary.

By contributing you agree your work is licensed under the MIT License.
