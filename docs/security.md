# Security model

Testa is a local developer tool that drives an app you don't necessarily trust.
To report a vulnerability, see [SECURITY.md](../SECURITY.md).

## No network, no telemetry, no keys

Testa never opens a network connection. OCR runs on-device through Apple
Vision.

## Transport

Each simulator gets a per-user Unix socket, `~/.testa/daemon-<udid>.sock`, with
mode `0600`. Nothing listens on a port.

- Reads and writes are timeout-bounded on both ends, and `SIGPIPE` is ignored.
- Line framing is capped at 10 MiB, so a runaway peer cannot exhaust memory.
- Spawning the daemon takes a lock, so two concurrent first calls cannot start
  two daemons for the same device.

## Files and limits

- Every file Testa writes is path-guarded: screenshots, recordings, vdiff
  baselines and heatmaps, JUnit XML, artifact bundles.
- Gesture and wait durations are clamped.
- The accessibility walk has a deadline, so a pathological tree produces a
  partial snapshot instead of a hang.

## Screen text is untrusted input

Accessibility labels, OCR output, log lines and crash reports come from the app
under test, not from you. Testa escapes and truncates them in snapshots
(`"` → `\"`, newlines → `\n`, long strings → `…`), so a crafted label cannot
forge extra element lines. The MCP tool descriptions and the skill tell the
model the same thing.

Escaping preserves the *shape* of the output, not its trustworthiness. If a
screen says "ignore your previous instructions", nothing in Testa can stop a
model from reading it. Testa makes sure it arrives clearly labelled as data.
Treat what comes back as something to assert on, and report anything that
looks like an instruction as a finding.
