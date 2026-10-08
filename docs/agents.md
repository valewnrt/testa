# Using Testa from an AI agent

Testa is a CLI first, so any agent that can run shell commands can use it.
For agents that speak the [Model Context Protocol](https://modelcontextprotocol.io),
`testa mcp` runs an MCP server over stdio.

## Claude Code

`testa setup` does both steps for you: it installs the skill to
`~/.claude/skills/testa/` and runs `claude mcp add`. To do it by hand:

```bash
claude mcp add testa -- testa mcp
```

The skill ([`skills/testa/SKILL.md`](../skills/testa/SKILL.md)) teaches the
observe → act → verify loop. The repo is also a Claude Code plugin
([`.claude-plugin/plugin.json`](../.claude-plugin/plugin.json) +
[`.mcp.json`](../.mcp.json)) that brings the skill and the MCP server together.

## Codex

```bash
codex mcp add testa -- testa mcp
```

## Cursor, Windsurf, VS Code and other MCP clients

Add this to the client's MCP config (for Cursor: `~/.cursor/mcp.json` or
`.cursor/mcp.json` in your project):

```json
{
  "mcpServers": {
    "testa": { "command": "testa", "args": ["mcp"] }
  }
}
```

If the client prefers npm packages, `npx @valewnrt/testa-mcp` works too. It is a
thin launcher: it downloads nothing and needs `testa` installed already.

## Tools

The server exposes **13 tools by default**: `ui`, `see`, `find`, `tap`,
`tapText`, `type`, `setValue`, `swipe`, `scrollTo`, `wait`, `assert`, `launch`,
`screenshot`. That covers observing, driving and asserting. Every extra tool
costs context and makes tool choice harder for the model, so the rest is
opt-in.

`testa mcp --full` (or `TESTA_MCP_FULL=1`) exposes **40**, adding
install/terminate/apps/open/logs/crashes/permission/record/push/info,
location/statusBar/appearance/contentSize/locale/addMedia/clipboard/biometry,
and clear/key/keycombo/button/drag/dragdrop/longpress/pinch/rotate.

Every tool takes an optional `udid` to target a specific simulator and validates
required arguments up front. Tools that return app-authored text say so in
their description (see [Security](security.md#screen-text-is-untrusted-input)).

## Why text instead of screenshots

Reading the screen as structured text is the biggest lever on what an
agent-driven run costs. Measured on the native SwiftUI showcase (iPhone 14 Pro
simulator, 19 on-screen elements):

| per step | bytes | ~tokens |
|---|---:|---:|
| `testa ui` | 809 | **203** |
| `testa ui diff` (unchanged screen) | 12 | 3 |
| `testa see` (OCR) | 240 | 60 |
| screenshot, native vision encoder | — | ~1,512 |
| screenshot, base64 into the prompt | 205,368 | 51,342 |

`ui` is about 7× cheaper than a screenshot on a provider with a vision encoder,
and it gives the model tap-ready coordinates and stable ids instead of a guess.
Flow replay brings the cost of re-running a suite to zero.

[`bench/`](../bench/) has the method, the caveats and a script that reproduces
this on your own app. It measures Testa only; no other tool was benchmarked.
