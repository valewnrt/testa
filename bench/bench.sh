#!/bin/bash
# Token benchmark for Testa's screen-reading modes.
#
# What it measures, on the app that is currently in the foreground of the booted
# simulator:
#
#   ui          the accessibility snapshot an agent normally reads
#   ui diff     the incremental snapshot (what acting commands append for free)
#   see         on-device OCR of every visible text region
#   screenshot  a PNG, base64-encoded — what a screenshot-driven agent uploads
#
# For each: bytes on the wire, and an approximate token count. Text tokens use
# the usual chars/4 rule of thumb. The image row is deliberately reported two
# ways, because there is no single honest number:
#
#   * base64 chars / 4 — what it costs if the image is pasted as text
#   * the provider's own vision-token formula — every provider differs, so the
#     script prints the raw pixel dimensions and leaves the arithmetic labelled
#     rather than pretending one formula is universal.
#
# This measures Testa only. It makes no claim about any other tool's numbers.
#
# Usage:  bench/bench.sh [runs]          (default 5 timing runs)
#         TESTA=/path/to/testa bench/bench.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNS="${1:-5}"

# Prefer this checkout's release build over whatever is on PATH — benchmarking a
# stale installed binary is how numbers quietly go wrong.
if [ -z "${TESTA:-}" ]; then
  if [ -x "$ROOT/.build/release/testa" ]; then TESTA="$ROOT/.build/release/testa"
  elif [ -x "$ROOT/.build/debug/testa" ]; then TESTA="$ROOT/.build/debug/testa"
  else TESTA="$(command -v testa || true)"
  fi
fi
[ -n "$TESTA" ] || { echo "no testa binary found (build it: swift build -c release)" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

"$TESTA" info > "$TMP/info.txt" 2>&1 || {
  echo "no booted simulator (boot one: testa boot \"iPhone 17 Pro\")" >&2
  cat "$TMP/info.txt" >&2
  exit 1
}

echo "testa:  $TESTA ($("$TESTA" version 2>/dev/null || echo "?"))"
echo "device: $(cat "$TMP/info.txt")"
echo "runs:   $RUNS"
echo ""

# ---------------------------------------------------------------- measurement

# Best-of-N wall clock in milliseconds for a whole CLI invocation (process spawn
# + socket round trip + the work itself). Best-of, not mean: the floor is the
# reproducible number; the tail is whatever else the machine was doing.
best_ms() {
  local best=999999 i start end ms
  for ((i = 0; i < RUNS; i++)); do
    start=$(python3 -c 'import time; print(int(time.time()*1000))')
    "$@" > /dev/null 2>&1
    end=$(python3 -c 'import time; print(int(time.time()*1000))')
    ms=$((end - start))
    [ "$ms" -lt "$best" ] && best=$ms
  done
  echo "$best"
}

bytes_of() { wc -c < "$1" | tr -d ' '; }
tok() { echo $(( ($1 + 3) / 4 )); }   # chars/4, rounded up

# Warm the daemon and settle the screen before anything is timed.
"$TESTA" ui > /dev/null 2>&1
"$TESTA" ui > /dev/null 2>&1

"$TESTA" ui        > "$TMP/ui.txt"      2>/dev/null
"$TESTA" ui diff   > "$TMP/uidiff.txt"  2>/dev/null
"$TESTA" see       > "$TMP/see.txt"     2>/dev/null
"$TESTA" screenshot "$TMP/shot.png" > /dev/null 2>&1
base64 -i "$TMP/shot.png" | tr -d '\n' > "$TMP/shot.b64"

# The near-no-op command isolates fixed CLI overhead (dyld + socket connect), so
# the marginal cost of actually reading the screen is visible.
T_INFO=$(best_ms "$TESTA" info)
T_UI=$(best_ms "$TESTA" ui)
T_UIDIFF=$(best_ms "$TESTA" ui diff)
T_SEE=$(best_ms "$TESTA" see)
T_SHOT=$(best_ms "$TESTA" screenshot "$TMP/shot.png")

B_UI=$(bytes_of "$TMP/ui.txt")
B_UIDIFF=$(bytes_of "$TMP/uidiff.txt")
B_SEE=$(bytes_of "$TMP/see.txt")
B_PNG=$(bytes_of "$TMP/shot.png")
B_B64=$(bytes_of "$TMP/shot.b64")

PX=$(python3 - "$TMP/shot.png" <<'PY'
import struct, sys
with open(sys.argv[1], 'rb') as f:
    head = f.read(24)
w, h = struct.unpack('>II', head[16:24])
print(f"{w}x{h}")
PY
)

# ---------------------------------------------------------------- report

printf '%-14s %10s %12s %10s\n' "mode" "bytes" "~tokens" "best ms"
printf '%-14s %10s %12s %10s\n' "-----------" "---------" "-----------" "---------"
printf '%-14s %10d %12d %10d\n' "ui"          "$B_UI"     "$(tok "$B_UI")"     "$T_UI"
printf '%-14s %10d %12d %10d\n' "ui diff"     "$B_UIDIFF" "$(tok "$B_UIDIFF")" "$T_UIDIFF"
printf '%-14s %10d %12d %10d\n' "see (OCR)"   "$B_SEE"    "$(tok "$B_SEE")"    "$T_SEE"
printf '%-14s %10d %12s %10d\n' "screenshot"  "$B_PNG"    "-"                  "$T_SHOT"
printf '%-14s %10d %12d %10s\n' "  → base64"  "$B_B64"    "$(tok "$B_B64")"    "-"
echo ""
printf 'screenshot is %s px. The base64 row is the honest upper bound (image\n' "$PX"
printf 'pasted as text). A provider with a native vision encoder charges much\n'
printf 'less — but every provider counts differently, so here is one worked\n'
printf 'example rather than a universal number:\n'
python3 - "$PX" "$B_UI" <<'PY'
import sys
w, h = (int(v) for v in sys.argv[1].split('x'))
ui_t = -(-int(sys.argv[2]) // 4)
# Anthropic's documented shape: long edge capped at 1568 px, then w*h/750.
cap = 1568
s = min(1.0, cap / max(w, h))
sw, sh = round(w * s), round(h * s)
vt = round(sw * sh / 750)
print(f"  resize long edge to {cap}px -> {sw}x{sh}, then (w*h)/750 = ~{vt:,} vision tokens")
print(f"  that is still ~{vt/ui_t:.0f}x one `ui` snapshot ({ui_t} tokens), per step.")
PY
echo ""
printf '"ui diff" is measured against an unchanged screen, so it is the floor:\n'
printf 'what a no-op costs. After a real action it carries only what moved.\n'
echo ""
printf 'fixed CLI overhead (testa info, a near-no-op): %d ms\n' "$T_INFO"
printf 'marginal cost of a warm ui snapshot:           %d ms\n' "$((T_UI - T_INFO))"
printf '  (an MCP client pays only the marginal cost — the server process is\n'
printf '   already running, so there is no per-call spawn.)\n'
echo ""

python3 - "$B_UI" "$B_B64" <<'PY'
import sys
ui, b64 = int(sys.argv[1]), int(sys.argv[2])
ui_t, img_t = -(-ui // 4), -(-b64 // 4)
print(f"ratio: one screenshot ≈ {img_t / ui_t:.0f}x the tokens of one ui snapshot")
for steps in (10, 50):
    print(f"  {steps:3d}-step flow:  ui {ui_t*steps:>9,} tok   vs   screenshots {img_t*steps:>11,} tok")
PY
