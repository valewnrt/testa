# @valewnrt/testa-mcp

Thin launcher for the **[Testa](https://github.com/valewnrt/testa)** MCP server — drive the
iOS Simulator from an AI agent: real HID gestures, token-efficient accessibility snapshots
(~200 tokens/screen instead of screenshots), Vision-OCR fallback, deterministic replay flows.

This package ships **no binary and downloads nothing**. It locates an already-installed
native `testa` and execs `testa mcp`, forwarding stdio verbatim.

## Install the native binary first (macOS only)

```sh
brew tap valewnrt/testa
brew install testa
testa setup
```

## Use

```sh
npx @valewnrt/testa-mcp            # 13 token-lean core tools
npx @valewnrt/testa-mcp --full     # all 40 tools (push, location, biometry, …)
```

Or register directly with Claude Code (no npm needed at all):

```sh
claude mcp add testa -- testa mcp
```

Environment: `TESTA_BIN` overrides binary discovery; `--udid <udid>` targets a specific
simulator. Docs, flows, CI action and benchmarks: https://github.com/valewnrt/testa
