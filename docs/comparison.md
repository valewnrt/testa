# How Testa compares

These are all good tools, and several are more mature or broader than Testa.
This page exists to help you pick, not to score points. If something here is
wrong or out of date, please [open an issue](https://github.com/valewnrt/testa/issues/new/choose).

| | Testa | [Argent](https://github.com/software-mansion/argent) | [idb](https://github.com/facebook/idb) | [Appium](https://appium.io) | [Maestro](https://maestro.dev) |
|---|:--:|:--:|:--:|:--:|:--:|
| Platforms | iOS | iOS · Android | iOS | iOS · Android · web | iOS · Android |
| Built for AI agents (MCP, compact snapshots) | ✅ | ✅ | — | — | partial¹ |
| Works on screens with no accessibility (OCR) | ✅ | — | — | — | — |
| Pinch · rotate · drag-and-drop · multi-touch | ✅ | partial² | ✅ | ✅ | partial² |
| Declarative flows replayed in CI | ✅ | partial² | — | code | ✅ |
| Record an agent session as a flow | ✅ | partial² | — | partial² | partial² |
| Visual regression built in | ✅ | partial² | — | plugin | cloud |
| Device environment (push, location, biometrics, appearance) | ✅ | partial² | partial² | ✅ | partial² |
| Accessibility audit as a CI gate | ✅ | — | — | — | — |
| Runtime | one native binary | Node | Python + companion | Node + driver | JVM |
| License | MIT | Apache-2.0 + proprietary binaries | MIT | Apache-2.0 | Apache-2.0 |
| Live debugging & profiling (logs, network, RN tree, Instruments) | — | ✅ | partial² | — | — |

¹ Maestro has an MCP server; its snapshots are not designed around token cost.
² Partial, plugin-only, commercial tier, or not clearly documented. Where a
project's docs didn't settle the question, it's marked partial rather than
guessed.

## When to use something else

- **You need Android too.** Use Maestro or Appium.
- **You want deep runtime debugging** (network inspector, React Native component
  tree, profiling). Argent covers this; Testa doesn't.
- **You test on real devices.** Testa only drives the Simulator.
- **You already have a large XCUITest suite.** Keep it. Testa is for the
  agent loop and for flows that are cheap to record, not a replacement for
  in-process unit or UI tests.

## Where Testa fits

Testa is fully open, has no runtime dependencies, drives screens that expose no
accessibility through on-device OCR, and uses the same tool for the agent loop
and for token-free CI replay. It does one platform and tries to do it
thoroughly.
