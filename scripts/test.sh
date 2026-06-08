#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

export XDG_DATA_HOME="$TMPDIR/data"
export XDG_CACHE_HOME="$TMPDIR/cache"
export XDG_STATE_HOME="$TMPDIR/state"
export XDG_CONFIG_HOME="$TMPDIR/config"
export OPENAI_API_KEY="dummy"

nvim --headless --clean -u NONE -i NONE --cmd "set rtp+=$ROOT" \
  -c "luafile $ROOT/tests/run.lua" \
  -c "qa"
