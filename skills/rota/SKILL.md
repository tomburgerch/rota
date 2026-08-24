---
name: rota
description: Use whenever a session touches Claude Code logins, quota, or account switching on a machine that runs a rota seat pool (several Claude Max seats, one CLAUDE_CONFIG_DIR each under ~/.claude-pool). Covers reading usage, switching seats, logging a seat in, and the rules that keep credentials from being destroyed. Not for headless runner slots.
---

# rota: working next to a seat pool without breaking it

A machine with rota installed has one directory per paid Claude Max seat under
`~/.claude-pool/<seat>/`, a pointer in `~/.claude.json` naming the active seat, a
`claude` shim on PATH that pins every launch to that seat, and a keeper daemon
that measures usage every ten minutes and switches before a wall. The one fact
behind every rule below: Claude Code OAuth refresh tokens are single-use, so a
credential that exists twice kills itself.

## Read before you act

- Quota: `rota usage --json` (or `rota usage` for the table). Rows carry
  `fetched_at`; older than 60 minutes is stale, and a stale row is not evidence.
  Do not hand-roll a call to the usage API.
- Which seat a live session bills to: `ps eww -p <pid> | grep -o 'CLAUDE_CONFIG_DIR=[^ ]*'`.
- Identity of a directory: `jq -r .oauthAccount.emailAddress <dir>/.claude.json`.
  Never from the directory name, never from `claude auth status`.
- What the daemon last did: `rota keeper-status`.

## Switching

- `rota switch` picks the seat whose weekly window resets soonest and still has
  room; `rota switch <seat>` names one. Idle sessions restart onto it, sessions
  mid-work are left alone and converge on their own later.
- A running session never changes seat. If you need this session on another
  seat, finish or restart it.

## Logging in

- `rota login <seat>` opens Claude pinned to that seat's directory; type
  `/login` there. One login per seat per machine, once.
- If you typed `/login` in an ordinary pane by mistake, stop. The keeper homes
  the displaced login into the right directory on its first tick after that
  pane exits (it never moves a credential a live process holds). A second
  login mints a second chain and one of the two will die.

## Never

- Never copy, move, scp, or restore a `.credentials.json` by hand. The sanctioned
  mutations are `rota switch`, `rota reconcile --apply`, `rota normalize`,
  `rota adopt-shared`, and the keeper; all are lock-held and identity-checked.
- Never set `CLAUDE_CONFIG_DIR=$HOME/.claude` (nested-config trap).
- Never start ordinary work with an explicit `CLAUDE_CONFIG_DIR`; a bare
  `claude` follows the pointer. Explicit pins are for capturing a login only.
- Never delete a Keychain item to "fix" a login; the keeper reconciles Keychain
  and file copies every tick.

## When something looks wrong

| Symptom | Meaning | Do |
|---|---|---|
| `rota usage` warns billing differs from claim | live sessions still on the previous seat | nothing; `rota switch <current>` converges idle panes now |
| a seat shows `needs login` or `dead-refresh` | that chain is dead (revoked, password change) | `rota login <seat>` |
| a seat shows `no active window yet` | it has not been used since its weekly reset; nothing to measure yet | one small request opens a window; the keeper does this at WARM_AT |
| every row is `cached` | the usage API is rate-limiting (429) under many sessions | wait; do not switch on cached rows |
| cred-guard report | an unpinned session is writing the shared credential | read `~/.config/claude-failover/cred-guard-report.txt`; it names the one command |
