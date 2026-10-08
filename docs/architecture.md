# How Testa works

```
agent ──► testa (CLI)            ──┐
agent ──► testa mcp (MCP server) ──┤ Unix socket (~/.testa/daemon-<udid>.sock, 0600)
CI    ──► testa flow run         ──┘
                                   ▼
                              testad (warm daemon)
                                   │  Obj-C engine, dlopen'd private frameworks
                    ┌──────────────┼───────────────┐
                    ▼              ▼                ▼
              SimulatorKit    CoreSimulator   AccessibilityPlatformTranslation
              (Indigo HID)    (SimDevice)     (AXPTranslator → a11y tree)  + Vision (OCR)
                    └──────────────┴────────────────┘
                          booted iOS Simulator
```

One binary is the CLI, the daemon and the MCP server. The first call for a
simulator spawns a daemon that keeps the device connection, the accessibility
translator and the HID client warm, so later calls take about 60 ms.

- **Touch and buttons.** Testa reimplements the Indigo HID wire format used by
  `SimDeviceLegacyHIDClient`. Taps, drags, multi-touch and hardware buttons are
  byte-for-byte what the simulator's guest HID service expects, not synthesized
  XCTest events.
- **Accessibility.** `AXPTranslator` is driven with a token delegate that turns
  each attribute read into an async `SimDevice` XPC request. The resulting tree
  is in point coordinates that match the tap space.
- **OCR.** Apple Vision runs over an in-process framebuffer capture (IOSurface).
- **Device environment.** Push, location, appearance, locale and so on go
  through public `simctl` APIs.

## Self-healing HID

The HID connection can die under a long-lived daemon. A SpringBoard or
backboardd relaunch, or a guest userspace reboot, invalidates its mach port
(`Mach port invalid, device disconnected`) while every read path keeps working.

Testa detects the failed send, re-creates the client and retries once. It also
revives the client proactively after three gestures in a row that changed
nothing, and says so in the reply. `testa status` shows the state:

```console
$ testa status
running: pong iPhone 17 Pro hid=ok        # hid=stale ⇒ gestures would go nowhere
```

## New Xcode versions

Testa loads Apple's private simulator frameworks. That's what makes it fast and
dependency-free, and it's also the part a new Xcode can break without notice.
Two things make this a managed risk:

- **`testa layout`** re-derives the Indigo HID struct offsets from the live
  `SimulatorKit` and fails loudly if a field moved. Run it after any Xcode
  update; it takes milliseconds.
- **[`xcode-beta.yml`](../.github/workflows/xcode-beta.yml)** runs weekly. It
  builds, tests, runs `testa layout` and replays the smoke flow against every
  Xcode on the runner, betas included. When a beta breaks something, its badge
  goes red, so the fix can land before the GA release.

## Why iOS only

Cross-platform mobile automation tools are built on the intersection of what
iOS and Android can both do. Anything iOS-specific ends up behind an escape
hatch or missing.

Targeting one platform lets Testa reimplement the HID wire format instead of
approximating gestures, drive `AXPTranslator` directly instead of going through
WebDriver, run Vision OCR in-process, and expose Face ID, Dynamic Type, APNs
payloads and status-bar overrides as first-class commands.

Real devices and Android are out of scope. If you need both platforms,
[Maestro](https://maestro.dev) or [Appium](https://appium.io) are good choices.

## Source layout

| Path | What's there |
|---|---|
| `Sources/TestaEngine/` | Obj-C engine: HID injection, accessibility tree, screenshot, OCR |
| `Sources/TestaKit/` | Pure, simulator-free model code (snapshots, flows, audit); unit-tested |
| `Sources/testa/` | Daemon, CLI, MCP server, `simctl` wrapper |
| `examples/` | SwiftUI and Expo showcases that double as the E2E suite |
| `skills/testa/` | The Claude Code skill |
| `bench/` | Token benchmark |
