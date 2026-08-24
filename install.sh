#!/usr/bin/env bash
#
# install.sh: put rota on this machine. Idempotent; re-run after every
# `git pull` is harmless (everything is a symlink into this checkout, so a
# pull ships fixes on its own).
#
#   install.sh               install everything
#   install.sh --no-agents   skip the launchd agents (keeper + cred-guard)
#   install.sh --uninstall   remove the symlinks and agents; state is kept
#   install.sh --help
#
# What it does:
#   1. ~/.local/bin/rota    -> <checkout>/bin/rota
#   2. ~/.local/bin/claude  -> <checkout>/lib/rota-shim.sh   (the per-seat pin)
#      A native install (~/.local/share/claude/versions/<ver>, where the
#      self-installer had made ~/.local/bin/claude a symlink to the binary)
#      gets its real binary parked at ~/.local/libexec/claude-real first, so
#      the shim can still find it after taking the name. A Homebrew install
#      needs nothing: the shim finds /opt/homebrew/bin/claude itself.
#   3. warns when ~/.local/bin is not ahead of the real claude on PATH
#   4. ~/.config/claude-failover/keeper.conf from config/keeper.conf.example
#      when there is none yet (the config dir honours CLAUDE_FAILOVER_HOME)
#   5. renders launchd/com.rota.*.plist into ~/Library/LaunchAgents and loads
#      them (macOS only; on Linux this step is skipped with a note)
#
# What it never does: copy, move or read a credential; touch ~/.claude-pool;
# create the accounts file. `rota login <seat>` is the next step.

set -euo pipefail

ROTA_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG_DIR="${CLAUDE_FAILOVER_HOME:-$HOME/.config/claude-failover}"
BIN_DIR="$HOME/.local/bin"
LIBEXEC="$HOME/.local/libexec"
LOG_DIR="$HOME/Library/Logs/rota"
AGENT_DIR="$HOME/Library/LaunchAgents"
LABELS=(com.rota.keeper com.rota.cred-guard)
NATIVE_VERSIONS="$HOME/.local/share/claude/versions"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m  %s\n' "$*" >&2; }
skip() { printf '\033[1;33m-\033[0m  %s\n' "$*"; }
die()  { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

MODE=install
WITH_AGENTS=1
for a in "$@"; do
  case "$a" in
    --uninstall)  MODE=uninstall ;;
    --no-agents)  WITH_AGENTS=0 ;;
    -h|--help)    usage; exit 0 ;;
    *)            usage >&2; die "unknown flag: $a" ;;
  esac
done

is_macos() { [ "$(uname -s 2>/dev/null)" = "Darwin" ]; }

# "Does this symlink point into our checkout?" so uninstall never removes a
# `claude` or `rota` that belongs to something else.
points_into_checkout() {
  local t
  [ -L "${1:-}" ] || return 1
  t="$(readlink "$1" 2>/dev/null || true)"
  case "$t" in "$ROTA_HOME"/*) return 0 ;; esac
  return 1
}

# ── uninstall ───────────────────────────────────────────────────────────────
if [ "$MODE" = "uninstall" ]; then
  info "Uninstalling rota (state in $CFG_DIR and ~/.claude-pool is kept)"
  if is_macos; then
    for label in "${LABELS[@]}"; do
      plist="$AGENT_DIR/$label.plist"
      if [ -f "$plist" ]; then
        launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
        rm -f "$plist"
        ok "removed LaunchAgent $label"
      fi
    done
  fi
  if points_into_checkout "$BIN_DIR/rota"; then
    rm -f "$BIN_DIR/rota"; ok "removed $BIN_DIR/rota"
  fi
  if points_into_checkout "$BIN_DIR/claude"; then
    rm -f "$BIN_DIR/claude"
    if [ -x "$LIBEXEC/claude-real" ]; then
      # a native install had its binary parked here; give the name back so
      # `claude` keeps working with nothing pinned
      ln -sf "$(readlink "$LIBEXEC/claude-real" 2>/dev/null || printf '%s' "$LIBEXEC/claude-real")" "$BIN_DIR/claude"
      ok "removed the shim; $BIN_DIR/claude now points at the real binary again"
    else
      ok "removed the shim from $BIN_DIR/claude (the Homebrew/native claude on PATH takes over)"
    fi
  fi
  printf '\nDone. To also drop the state: rm -rf %s   (and ~/.claude-pool, which holds your logins)\n' "$CFG_DIR"
  exit 0
fi

# ── preflight ───────────────────────────────────────────────────────────────
command -v jq >/dev/null 2>&1 || warn "jq is not on PATH; the keeper and cred-guard need it (brew install jq)"
[ -f "$ROTA_HOME/lib/rota-engine.sh" ] || die "$ROTA_HOME/lib/rota-engine.sh is missing; run this from a complete checkout"
for f in "$ROTA_HOME"/lib/rota-*.sh; do
  bash -n "$f" 2>/dev/null || die "$f has a syntax error; refusing to install a broken script"
done
mkdir -p "$BIN_DIR"

# ── 1. rota ─────────────────────────────────────────────────────────────────
info "1. rota on PATH"
if [ -f "$ROTA_HOME/bin/rota" ]; then
  chmod +x "$ROTA_HOME/bin/rota" 2>/dev/null || true
  if [ -e "$BIN_DIR/rota" ] && [ ! -L "$BIN_DIR/rota" ]; then
    warn "$BIN_DIR/rota exists and is not a symlink; leaving it alone. Move it aside and re-run."
  else
    ln -sf "$ROTA_HOME/bin/rota" "$BIN_DIR/rota"
    ok "linked $BIN_DIR/rota -> $ROTA_HOME/bin/rota"
  fi
else
  warn "$ROTA_HOME/bin/rota is missing; the rota command was not linked"
fi

# ── 2. the claude shim ──────────────────────────────────────────────────────
info "2. the per-seat shim as $BIN_DIR/claude"
SHIM_SRC="$ROTA_HOME/lib/rota-shim.sh"
SHIM_DEST="$BIN_DIR/claude"
chmod +x "$SHIM_SRC" 2>/dev/null || true
BREW_CLAUDE=""
for c in /opt/homebrew/bin/claude /usr/local/bin/claude; do
  [ -x "$c" ] && { BREW_CLAUDE="$c"; break; }
done
NATIVE_REAL=""
if [ -L "$SHIM_DEST" ]; then
  _tgt="$(readlink "$SHIM_DEST" 2>/dev/null || true)"
  case "$_tgt" in
    "$NATIVE_VERSIONS"/*) [ -x "$_tgt" ] && NATIVE_REAL="$_tgt" ;;
  esac
fi
if [ -z "$NATIVE_REAL" ] && [ -x "$LIBEXEC/claude-real" ]; then
  NATIVE_REAL="$LIBEXEC/claude-real"       # parked by an earlier run or the keeper
fi
if [ -z "$NATIVE_REAL" ] && [ -d "$NATIVE_VERSIONS" ]; then
  _newest="$(ls -t "$NATIVE_VERSIONS" 2>/dev/null | head -1)"
  [ -n "$_newest" ] && [ -x "$NATIVE_VERSIONS/$_newest" ] && NATIVE_REAL="$NATIVE_VERSIONS/$_newest"
fi
# A claude that lives only on PATH (npm -g, nvm, a custom prefix): the shim scans
# PATH for the real binary at launch, so it is enough to know one exists that is
# not the shim itself (or a copy of it).
PATH_CLAUDE=""
while IFS= read -r c; do
  [ -n "$c" ] || continue
  [ "$c" -ef "$SHIM_DEST" ] && continue
  [ "$c" -ef "$SHIM_SRC" ] && continue
  head -c 4096 "$c" 2>/dev/null | grep -q 'ROTA_SHIM_MARKER' && continue
  PATH_CLAUDE="$c"; break
done < <(which -a claude 2>/dev/null || true)

if ! bash -n "$SHIM_SRC" 2>/dev/null; then
  # This file shadows `claude` itself. A syntax error here would take the CLI
  # down machine-wide, so it is gated on a parse before it is ever linked.
  warn "$SHIM_SRC has a syntax error; NOT linking it (it would shadow \`claude\` machine-wide)"
elif [ -z "$BREW_CLAUDE" ] && [ -z "$NATIVE_REAL" ] && [ -z "$PATH_CLAUDE" ]; then
  warn "no real claude found (nothing on PATH besides the shim, no /opt/homebrew/bin/claude, /usr/local/bin/claude, or native install under $NATIVE_VERSIONS)"
  warn "install Claude Code first, then re-run install.sh; the shim has nothing to exec yet"
elif [ -e "$SHIM_DEST" ] && [ ! -L "$SHIM_DEST" ]; then
  # A REAL binary sitting there (an npm/global install) is not ours to
  # replace: overwriting it would destroy the thing the shim needs to exec.
  warn "$SHIM_DEST exists and is NOT a symlink; leaving it alone. Move it aside, then re-run."
else
  if [ -n "$NATIVE_REAL" ] && [ "$NATIVE_REAL" != "$LIBEXEC/claude-real" ]; then
    # park the real binary at the stable path BEFORE the shim takes the name;
    # after the ln -sf below the versioned target is unreachable through PATH
    mkdir -p "$LIBEXEC"
    ln -sf "$NATIVE_REAL" "$LIBEXEC/claude-real"
    ok "native install: parked the real binary at $LIBEXEC/claude-real -> $NATIVE_REAL"
  fi
  ln -sf "$SHIM_SRC" "$SHIM_DEST"
  ok "linked $SHIM_DEST -> $SHIM_SRC (bypass with CLAUDE_SHIM_DISABLE=1)"
  if PINNED="$(CLAUDE_SHIM_DISABLE=1 "$SHIM_DEST" --version 2>/dev/null)"; then
    ok "the shim execs the real binary: $PINNED"
  else
    warn "\`claude --version\` through the shim did not answer; check $SHIM_DEST"
  fi
fi

# ── 3. PATH order ───────────────────────────────────────────────────────────
info "3. PATH order"
FIRST_CLAUDE="$(command -v claude 2>/dev/null || true)"
if [ -n "$FIRST_CLAUDE" ] && [ "$FIRST_CLAUDE" -ef "$SHIM_DEST" ] 2>/dev/null; then
  ok "$BIN_DIR is ahead of the real claude on PATH (\`claude\` resolves to the shim)"
else
  warn "$BIN_DIR is not ahead of the real claude on PATH (\`claude\` resolves to ${FIRST_CLAUDE:-nothing})."
  warn "Add this line to your shell profile (~/.zshrc or ~/.bashrc) and open a new shell:"
  printf '\n    export PATH="$HOME/.local/bin:$PATH"\n\n'
fi

# ── 4. config skeleton ──────────────────────────────────────────────────────
info "4. config in $CFG_DIR"
mkdir -p "$CFG_DIR"
if [ -f "$CFG_DIR/keeper.conf" ]; then
  skip "keeper.conf already exists; not touching it"
else
  cp "$ROTA_HOME/config/keeper.conf.example" "$CFG_DIR/keeper.conf"
  ok "wrote $CFG_DIR/keeper.conf from config/keeper.conf.example (every knob at its default)"
fi
if [ -f "$CFG_DIR/accounts" ]; then
  ok "accounts file present ($CFG_DIR/accounts)"
else
  skip "no accounts file yet; \`rota login <seat>\` creates the pool on first use (see config/accounts.example)"
fi

# ── 5. launchd agents ───────────────────────────────────────────────────────
info "5. launchd agents (keeper every 10 min, cred-guard every 5 min)"
if [ "$WITH_AGENTS" -eq 0 ]; then
  skip "--no-agents: not installing the launchd agents"
elif ! is_macos; then
  skip "not macOS: launchd agents skipped. Run \`rota keeper\` and \`rota cred-guard\` from cron or a systemd timer instead."
else
  mkdir -p "$LOG_DIR" "$AGENT_DIR"
  for label in "${LABELS[@]}"; do
    src="$ROTA_HOME/launchd/$label.plist"
    dest="$AGENT_DIR/$label.plist"
    [ -f "$src" ] || { warn "$src not found; skipping $label"; continue; }
    # bash substitution rather than sed, so a & or | in a path cannot corrupt the plist
    _tpl="$(cat "$src")"; _tpl="${_tpl//__ROTA_HOME__/$ROTA_HOME}"; _tpl="${_tpl//__HOME__/$HOME}"
    printf '%s\n' "$_tpl" > "$dest"
    launchctl bootout "gui/$(id -u)" "$dest" 2>/dev/null || true
    # bootout is ASYNC: a bootstrap racing the teardown can fail with
    # "Input/output error" and leave the job DOWN while this script claims
    # success. So: bootstrap, then VERIFY with `launchctl print`, re-issuing
    # the bootstrap each round; only a verified load prints "loaded".
    launchctl bootstrap "gui/$(id -u)" "$dest" 2>/dev/null || true
    loaded=0
    for _try in 1 2 3 4 5; do
      if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then loaded=1; break; fi
      sleep 1
      launchctl bootstrap "gui/$(id -u)" "$dest" 2>/dev/null || true
    done
    if [ "$loaded" -eq 1 ]; then
      ok "$label loaded and verified ($dest)"
      launchctl kickstart "gui/$(id -u)/$label" 2>/dev/null || true   # first tick now
    else
      warn "$label did not verify as loaded after 5 tries (bootout teardown may still be in flight)."
      warn "Load it by hand:  launchctl bootstrap gui/$(id -u) $dest"
    fi
  done
  ok "logs: $LOG_DIR/*.log and $CFG_DIR/keeper.log"
fi

cat <<EOT

Installed from $ROTA_HOME.

  next:  rota login <seat>      log one seat in (repeat per seat you own)
         rota usage             live quota per seat
         rota switch            move new launches to the seat that resets soonest
         rota keeper-status     what the keeper did on its last tick

  Uninstall: $ROTA_HOME/install.sh --uninstall
EOT
