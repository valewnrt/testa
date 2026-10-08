# Troubleshooting & known limitations

## Common problems

**`no booted simulator`.** Boot one with `testa boot "iPhone 17 Pro"`, or pass
`--udid <udid>` if several are running.

**Taps report success but nothing happens.** Run `testa status`. `hid=stale`
means the simulator's HID connection died (for example after a SpringBoard
restart). Testa normally heals this on its own; `testa stop` followed by any
command starts a fresh daemon.

**Something broke after an Xcode update.** Run `testa layout`. If it reports a
moved field, please [open a bug](https://github.com/valewnrt/testa/issues/new?template=bug_report.yml)
with its output and your Xcode version.

**Typed text has wrong characters.** HID keystrokes follow the *host* keyboard
layout, so a non-US layout can swap some symbols (on a German Mac, `z` and `y`).
Use `setvalue`, which bypasses the keyboard. Text that can't be typed via HID
at all (umlauts, emoji, `π`) is pasted automatically.

**The first command is slow.** The first call per simulator starts the daemon
and warms accessibility, which takes a few seconds. Later calls take about
60 ms. Logs are in `~/.testa/daemon-<udid>.log`.

## Limitations

- **Icon-only controls** with no text and no accessibility label are ambiguous
  to any automation. Use coordinates, or add an `accessibilityLabel`.
- **`testa locale` needs an app relaunch.** A running app has already read the
  locale.
- **Private frameworks can break on a new Xcode.** See
  [New Xcode versions](architecture.md#new-xcode-versions) for how this is
  caught early.
- **`vdiff` compares equal-sized images only.** A different device, orientation
  or scale is reported as a size change. Baselines are per device.
- **`testa audit` is a static check.** It finds missing labels, small targets
  and duplicates; it can't tell whether a label is good.
- **Simulator only.** Real devices and Android are out of scope
  ([why](architecture.md#why-ios-only)).
- **`testa record`** writes H.264 MP4; live streaming isn't implemented.
- **The npm package** `@valewnrt/testa-mcp` is a launcher only and downloads no
  binaries. Install `testa` with Homebrew first.
- **Release zips** are notarized only when built with a Developer ID via
  `release.sh`. Homebrew and `install.sh` build from source.
