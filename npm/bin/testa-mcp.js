#!/usr/bin/env node
'use strict';

// Thin launcher for the Testa MCP server.
//
// It deliberately does NOT download anything. Testa is a native macOS binary
// that dlopens Apple's simulator frameworks; shipping a prebuilt copy through
// npm would mean an unsigned, unauditable binary in a package tarball. So this
// shim only locates an already-installed `testa` and execs `testa mcp`,
// forwarding stdio verbatim (MCP speaks newline-delimited JSON-RPC on stdin /
// stdout, so the child must inherit both untouched).

const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const INSTALL_HINT = [
  'testa-mcp: the native `testa` binary was not found.',
  '',
  'Install it with Homebrew (builds from source, no notarized binary needed):',
  '',
  '  brew tap valewnrt/testa',
  '  brew install testa',
  '  testa setup',
  '',
  '…or from source:',
  '',
  '  git clone https://github.com/valewnrt/testa && cd testa && ./install.sh',
  '',
  'Once `testa` is on your PATH, `testa mcp` is itself a stdio MCP server —',
  'you can register it directly and skip this npm package entirely:',
  '',
  '  claude mcp add testa -- testa mcp',
  '',
  'Docs: https://github.com/valewnrt/testa',
].join('\n');

function isExecutableFile(candidate) {
  try {
    if (!fs.statSync(candidate).isFile()) return false;
    fs.accessSync(candidate, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

// PATH first (respects nvm-style shims, custom prefixes and ~/.local/bin), then
// the two Homebrew prefixes, then the common source-install location.
function findTesta() {
  const fromEnv = process.env.TESTA_BIN;
  if (fromEnv && isExecutableFile(fromEnv)) return fromEnv;

  const dirs = (process.env.PATH || '').split(path.delimiter).filter(Boolean);
  for (const extra of [
    '/opt/homebrew/bin',
    '/usr/local/bin',
    path.join(process.env.HOME || '', '.local', 'bin'),
  ]) {
    if (extra && !dirs.includes(extra)) dirs.push(extra);
  }

  for (const dir of dirs) {
    const candidate = path.join(dir, 'testa');
    if (isExecutableFile(candidate)) return candidate;
  }
  return null;
}

function main() {
  if (process.platform !== 'darwin') {
    process.stderr.write(
      'testa-mcp: macOS only — Testa drives the iOS Simulator, which exists ' +
        `only on macOS (this is ${process.platform}).\n`
    );
    process.exit(1);
  }

  const bin = findTesta();
  if (!bin) {
    process.stderr.write(INSTALL_HINT + '\n');
    process.exit(1);
  }

  // Everything after our own argv is passed through, so `npx @valewnrt/testa-mcp --full`
  // and `--udid <udid>` work exactly as they do on the CLI.
  const child = spawn(bin, ['mcp', ...process.argv.slice(2)], { stdio: 'inherit' });

  child.on('error', (e) => {
    process.stderr.write(`testa-mcp: could not run ${bin}: ${e.message}\n`);
    process.exit(1);
  });
  // Mirror the child's fate so supervisors see the real reason it stopped.
  child.on('exit', (code, signal) => {
    if (signal) {
      process.kill(process.pid, signal);
      return;
    }
    process.exit(code === null ? 1 : code);
  });

  // Forward the usual shutdown signals instead of orphaning the daemon client.
  for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
    process.on(sig, () => {
      try {
        child.kill(sig);
      } catch {
        /* already gone */
      }
    });
  }
}

main();
