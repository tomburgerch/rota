#!/usr/bin/env bash
# rota-engine.sh, launch an interactive Claude Code session against a
# POOL of local accounts, and switch to the next one with a single command when
# you hit a usage-window limit.
#
# WHY THIS IS SEMI-MANUAL (honest, not a bug): the Claude CLI has no native
# multi-account fallback and CANNOT hot-swap accounts mid-session, when an
# interactive session hits its limit it just stalls, it doesn't exit, so a
# wrapper can't auto-detect + switch (verified against docs.claude.com). What
# this DOES give you: (1) auto-pick the account so you never juggle
# CLAUDE_CONFIG_DIR by hand, (2) `next` = switch to the next account AND resume
# the same conversation (`claude --continue`) in one command when you wall.
#
# (A server-side agent fleet can fail over on its own; this is the local,
# interactive companion, and the engine behind the `rota` CLI.)
#
# Config: ~/.config/claude-failover/accounts , one "label|config_dir" per line,
# in YOUR preferred order (for local use put the SOONEST-to-expire account first,
# so it gets burned down before it resets). Lines starting with # are ignored.
# A commented template ships as config/accounts.example. Example:
#
#     personal@example.com|~/.claude-pool/personal
#     work@example.com|~/.claude-pool/work
#     team@example.com|~/.claude-pool/team
#
# First-time per extra account: log it into its own dir once,
#     CLAUDE_CONFIG_DIR=/Users/you/.claude-pool/work claude   # then /login, /quit
# (macOS keys the Keychain credential by a hash of the dir path, so each dir is
#  a separate account, logging into one never clobbers another.)
#
# NEVER capture an account by logging into the shared ~/.claude while sessions are
# running: a live session's token refresh rewrites .credentials.json from memory and
# clobbers the fresh login within minutes (observed 2026-07-19, a personal-seat login was
# silently reverted to the previous account). ALWAYS log new accounts into their own
# pool dir; ~/.claude is a pure runtime slot that only switch-all should write.
#
# ---------------------------------------------------------------------------
# WHERE `claude auth status` GETS ITS ANSWER, AND THE NESTED-CONFIG TRAP
# (the always-on box, 2026-07-30, proved side by side. This CORRECTS the conclusion shipped in
# PR #433, which recorded that auth status "is not a trustworthy identity source on
# this box" and that the source of its wrong answer was "unknown". Both halves were
# wrong. auth status was answering correctly the whole time; THIS SCRIPT was aiming
# it at the wrong file.)
#
# Claude Code resolves its config as $CLAUDE_CONFIG_DIR/.claude.json. With
# CLAUDE_CONFIG_DIR UNSET, which is how every real interactive session runs, that
# is ~/.claude.json, the file at the HOME ROOT. Setting CLAUDE_CONFIG_DIR=$HOME/.claude
# does NOT aim it at that file: it aims it at ~/.claude/.claude.json, a DIFFERENT file
# NESTED inside the directory. Both exist here, and they have drifted apart:
#
#   probe                                           reports
#   CLAUDE_CONFIG_DIR=$HOME/.claude auth status     team@example.com
#     ~/.claude/.claude.json oauthAccount           team@example.com     (stale, frozen 16:26)
#   env -u CLAUDE_CONFIG_DIR auth status            personal@example.com
#     ~/.claude.json oauthAccount                   personal@example.com (live, governs sessions)
#
# The pool dirs were never affected and need no change:
# CLAUDE_CONFIG_DIR=~/.claude-pool/personal correctly reads ~/.claude-pool/personal/.claude.json.
#
# WHAT auth status RENDERS is that config JSON's oauthAccount object: the email, orgId
# and orgName it prints match the file's emailAddress / organizationUuid /
# organizationName field for field, and with NO "Claude Code-credentials" Keychain item
# on this box BOTH probes above read the SAME ~/.claude/.credentials.json, so the only
# thing that can explain two different answers is the two different config files. That
# makes auth status a faithful reader of the DISPLAYED identity (the same field
# ccstatusline and /status show), NOT independent evidence about which account the
# CREDENTIAL bills. Useful, and now used, but for what it can actually see.
#
# It also explains the "disagrees FOREVER" behaviour logged on 2026-07-27 and
# 2026-07-30: switch-all moves oauthAccount in ~/.claude.json, while the old probe read
# ~/.claude/.claude.json, a file nothing in this script ever writes. It could never
# have agreed, however long the retry loop waited.
#
# The 2026-07-30 INCIDENT still stands, and so does its cost: every session was
# spending the team seat while `active`, the dashboard header and ccstatusline all said work,
# and the one account actually being burned was the row that printed NOT LOGGED IN.
# What changes is the diagnosis, and therefore what this script does about it.
#
# So identity comes from three signals, in this order:
#   1. ~/.claude.json .oauthAccount.emailAddress, the primary CLAIM, and the field
#      Claude Code's own UI and ccstatusline read, so this tool and the UI cannot
#      disagree.
#   2. the USAGE FINGERPRINT, the VERIFICATION, and the only signal that speaks about
#      the CREDENTIAL: two credentials whose seven_day.resets_at match to the MINUTE
#      belong to the same account (that instant is a property of the account's window,
#      not of the token). The shared credential is identified by a cadence match, by
#      having bytes identical to a pool copy, or by elimination when every other pool
#      copy has a demonstrably different cadence.
#   3. `env -u CLAUDE_CONFIG_DIR claude auth status`, a genuine third opinion that
#      should normally AGREE with 1. When it does not, the CLI resolved a different
#      config file than we read (an inherited CLAUDE_CONFIG_DIR is the usual cause),
#      which is a real warning worth printing rather than something to disclaim.
# 1 disagreeing with 2 is a loud WARNING, never a silent pick.
#
# THE NESTED FILE: NOT DELETED, RE-POINTED (resolved 2026-08-06). Deleting
# ~/.claude/.claude.json was never right, it may be a legacy artifact, and a probe using
# CLAUDE_CONFIG_DIR=$HOME/.claude would then get NO answer instead of a wrong one. But
# aiming it AT the root file is: nested_config_warning() already treats "nested and root
# are the same file" (`-ef`) as the healthy state, so replacing the stale copy with a
# symlink to ~/.claude.json makes that probe return the CORRECT account, and removes the
# drift permanently, one file, nothing left to disagree.
#
# `repair-nested` automates exactly that (back up the stale copy, symlink, verify the
# `-ef` now passes), and it is idempotent, so re-running it on a repaired box is a no-op.
# The warning still fires on any box that has NOT been repaired, so the trap stays visible
# until someone fixes it. The always-on box was repaired by hand on 2026-08-06 and verified:
# CLAUDE_CONFIG_DIR=$HOME/.claude and `env -u CLAUDE_CONFIG_DIR` now report the same
# account, and the warning is gone from `rota usage`.
#
# WHY THE LIVE CREDENTIAL IS SYNCED BACK INTO ITS POOL DIR: OAuth refresh tokens are
# single-use, so every rotation a running session performs on the shared ~/.claude
# credential kills whatever copy that account's pool dir still holds. Nothing used to
# sync it back, so within a day the pool copy of the account you are actively burning
# rots, and the one row you most need numbers for is the one row that has none.
# `usage` now copies the live credential back into its owner's pool dir (only ever
# shared → pool, and only when the shared file is NEWER), which makes the dashboard
# self-healing: one run and every account has a usable copy again.
#
# ---------------------------------------------------------------------------
# THE HUSK: WHAT ACTUALLY GUTS A POOL CREDENTIAL (the always-on box, 2026-08-07)
#
# Symptom: `rota usage` reported seat A as "no stored credential" a
# few hours after that account had been logged in and working. Its pool copy was a
# 1296-byte HUSK, refreshToken gone, expiresAt gone, only refreshTokenExpiresAt left.
# the personal seat was gutted to the identical shape. Both switch-all stashes still held complete
# credentials, so the good bytes existed the whole time and nothing looked at them.
#
# THE FIRST DIAGNOSIS WAS WRONG, and it is recorded here so nobody re-derives it. The
# obvious suspect was this script's own credential copies, sync_live_credential_back
# and switch-all's same-account force-sync, because both were gated on FRESHNESS
# (`-nt`) and never on content, so a husk that happened to be newer would be copied
# straight over a good pool copy. Plausible, and a real latent hazard. Not what
# happened.
#
# THE CONTROLLED OBSERVATION that settles it: both pool copies were restored from
# their stashes and verified complete; seat A was then given a FRESH interactive login;
# a single `usage` run was made and NOTHING else, no switch-all, no cp. Afterwards
# seat A was intact and the personal seat was back to a 1296-byte husk. The one variable that
# differed was TOKEN VALIDITY, not code path: seat A's token was live, the personal seat's restored
# token was already stale (its refresh token was dead).
#
# THE MECHANISM, therefore, is the HAIKU NUDGE in collect_usage, the one place this
# script hands a pool dir to the CLI:
#
#     (cd / && CLAUDE_CONFIG_DIR="$adir" claude -p "…" …)
#
# It runs only for an account whose usage fetch failed, i.e. exactly an account whose
# stored token is stale. The CLI then tries to refresh; when the REFRESH TOKEN is dead
# the server rejects it and the CLI CLEARS the credential it can no longer use,
# writing the husk itself. So the corrupting write is the Claude CLI's, not this
# script's; this script is what points the CLI at the file. That is still ours to fix,
# because it is our nudge, on our schedule, against our pool dir.
#
# WHAT THIS FILE DOES ABOUT IT:
#   1. cred_is_complete(), ONE predicate for "this file is a usable credential",
#      used everywhere instead of scattered ad-hoc checks.
#   2. Detect the gutting AT THE NUDGE (complete before → incomplete after) and say
#      plainly what happened: the refresh was rejected and the credential was cleared,
#      so the account NEEDS A RE-LOGIN. Never "no stored credential", which is what
#      sent the operator hunting for a login that had already happened.
#   3. Remember it. `$CFG_DIR/dead-refresh/<label>` records the size+mtime (never any
#      content) of the credential whose refresh was rejected, so the next run neither
#      re-nudges that exact credential nor restores it again from a stash holding the
#      same dead bytes. Without this the "helpful" self-heal below becomes an infinite
#      heal→nudge→gut loop that rewrites the file every single run.
#   4. heal_pool_credential(), a gutted or missing pool copy IS restored from its
#      stash when that stash is complete, in date, and NOT known-dead (husk kept as
#      <file>.husk-bak-<date>). Once per account per run, never in a loop.
#   5. cred_overwrite_refused() at every credential copy in this script. This is
#      DEFENCE IN DEPTH, not the fix for the incident above: no copy here was proved
#      to have gutted anything. It is cheap and it is correct, a copy that would
#      trade a complete credential for an incomplete one is refused and logged.
# ---------------------------------------------------------------------------
#
# Usage:
#   rota failover [args...]           Launch claude on the CURRENT account (args passed through)
#   rota failover next                Advance to the next account + `claude --continue`
#   rota failover reset               Go back to the first (preferred) account
#   rota failover status              Show accounts, which is current, and each login state.
#                                     loggedIn is true when the account has a usable
#                                     stored credential OR is the account governing the
#                                     shared ~/.claude (whose pool copy is allowed to be
#                                     stale, live sessions burn its refresh tokens).
#   rota failover here                Print the current account's CLAUDE_CONFIG_DIR (for scripts)
#   rota failover repair-nested [--dry-run]
#                                     Fix the NESTED-CONFIG TRAP on this box: replace a
#                                     stale ~/.claude/.claude.json with a symlink to
#                                     ~/.claude.json, so a CLAUDE_CONFIG_DIR=$HOME/.claude
#                                     probe reports the SAME account a real session runs
#                                     as, and the two can never drift apart again. The
#                                     stale copy is kept as
#                                     ~/.claude/.claude.json.stale-bak-<date> (never
#                                     clobbering an existing backup). Needs no accounts
#                                     file, the trap is about ~/.claude, not the pool.
#                                     Idempotent and conservative: "nothing to repair"
#                                     when the nested file is absent, "already healthy"
#                                     when it already resolves to ~/.claude.json (no
#                                     second backup on a re-run), and it REFUSES when
#                                     ~/.claude.json is missing or not valid JSON,
#                                     there is nothing safe to point at, so the nested
#                                     file is left byte-for-byte alone. Prints the email
#                                     the nested file claimed before and the one it
#                                     resolves to after. --dry-run reports and changes
#                                     nothing.
#   rota failover active              Print ONLY the email governing the shared ~/.claude
#                                     (one line, nothing else, for scripts, e.g.
#                                     the dashboard's account endpoint). Exits 3 when it can't
#                                     be determined. Identity comes from
#                                     ~/.claude.json's oauthAccount, cross-checked
#                                     against pool credential BYTES (see the block
#                                     above), no `claude` subprocess, so it stays fast.
#   rota failover usage [--no-refresh] [--json] [--verbose] [--color|--no-color]
#   rota failover usage --record <alias> <weekly-used-%> [<5h-used-%>] [<weekly-reset-iso>]
#                                     Usage dashboard (alias: `accounts`), laid out in
#                                     FOUR BUCKETS so the first five lines answer the
#                                     question it is actually run to answer, which
#                                     account am I on, which can I switch to right now,
#                                     which have a number nobody has measured, and which
#                                     are dead until when:
#                                       ▶ ACTIVE        the shared ~/.claude account,
#                                                       with a 15-cell meter per window
#                                                       whose FILLED cells are what is
#                                                       LEFT (a full bar is good news)
#                                       ALTERNATIVES    every other account clearing the
#                                                       health floor, the SAME predicate
#                                                       the optimizer picks with, so the
#                                                       table can never advertise a switch
#                                                       the optimizer refuses, each with
#                                                       the exact `rota switch <alias>`
#                                       UNMEASURED      quota UNKNOWN, not spent: no source
#                                                       (live fetch, cache, peer, hand
#                                                       reading) produced a number for the
#                                                       window you would spend right now,
#                                                       because the window behind it has
#                                                       rolled or the usage API answered
#                                                       429. The SEAT is fine and only the
#                                                       number is missing. Names each
#                                                       cancelled seat's end date and the
#                                                       `rota usage --record` that
#                                                       answers it
#                                       UNAVAILABLE     everything else, with a SHORT
#                                                       reason and when it comes back
#                                                       (a seat past its `ends` date in
#                                                       billing.json reads `seat ended
#                                                       <date>`, the one state that
#                                                       really is finished)
#                                     and the recommendation LAST, where it reads as the
#                                     conclusion of the picture above it, followed by the
#                                     PANES block, how many tmux panes in the configured
#                                     tmux session are
#                                     idle vs working, and how many may still be running
#                                     on the PREVIOUS account. NB "session" is overloaded:
#                                     this dashboard is about the 5-HOUR USAGE BLOCK (what
#                                     Claude Code's statusline calls "Session: 93%"), while
#                                     a tmux pane listing is about tmux panes. The
#                                     PANES block is the cross-link between the two, and it
#                                     is a silent no-op when ROTA_TMUX_SESSION is unset
#                                     or names a session that does not exist.
#                                     Windows are shown in BOTH polarities: the metered
#                                     row leads with "% left" so it agrees with its own
#                                     bar ("84% left · 16% used"), while every SENTENCE
#                                    , exclusion reasons, the recommendation, the mode
#                                     line, still leads with USED, the number in the
#                                     same position as Claude Code's own statusline. So
#                                     neither reading has to be done in your head, and
#                                     the two surfaces can't look like they name
#                                     different accounts.
#                                     --verbose/-v: restores the dense detail the default
#                                     view relocated (nothing is deleted), the slot path,
#                                     the identity/fingerprint line, the note/why lines
#                                     and the full `skipped …` sentences.
#                                     --color / --no-color: force colour on or off.
#                                     Default: colour when stdout is a TTY and NO_COLOR
#                                     is unset. With colour off the output carries no
#                                     escape bytes at all, so it stays greppable.
#                                     The weekly figure is the BINDING weekly limit: the
#                                     highest `percent` across the response's `limits`
#                                     entries whose group is "weekly", so a per-model
#                                     (scoped) cap that will wall you before the all-model
#                                     one is the number shown, annotated
#                                     "(binding: <model>)". Falls back to seven_day when
#                                     the response carries no usable `limits` array.
#                                     Plus reset times
#                                     in local time, the active account first, plus a
#                                     recommendation, which runs in one of TWO MODES
#                                     and always says which one it used:
#                                     FLOOR (the default, and the right rule in
#                                     general): spend the headroom that expires
#                                     soonest, as long as the account clears a health
#                                     floor (>=20% weekly and >=10% 5h remaining;
#                                     override with CLAUDE_FAILOVER_MIN_WEEKLY /
#                                     CLAUDE_FAILOVER_MIN_SESSION). Moving off an
#                                     account with 12% left costs nothing when a fresh
#                                     account is waiting, you come back after it
#                                     resets.
#                                     BURN-DOWN (scarcity): when NO other account has
#                                     comfortable weekly headroom, the best one is
#                                     under 50% left (override with
#                                     CLAUDE_FAILOVER_COMFORTABLE), there is nowhere
#                                     good to go, so leaving 12% behind is expensive.
#                                     Then you STAY on the active account until its
#                                     weekly window is at or under the EXHAUSTION
#                                     THRESHOLD, 2% left by default (~98-100% used;
#                                     override with CLAUDE_FAILOVER_EXHAUSTED), and
#                                     only then does the floor rule above pick the
#                                     target. ONE exception: when the active account's
#                                     5h session window is itself at/under the
#                                     threshold you are BLOCKED right now, so switching
#                                     genuinely helps and the reason names that window.
#                                     CLAUDE_FAILOVER_MODE=floor|burn-down forces one
#                                     regardless of the trigger (default `auto`).
#                                     The floor governs only what you move ONTO. An
#                                     account with NO
#                                     active window (utilization 0, resets_at null,
#                                     fully fresh, 100% headroom) is recommendable and
#                                     clears the floor, but ranks BEHIND any healthy
#                                     account that has a real reset, since nothing of
#                                     its headroom is expiring; it wins when no healthy
#                                     account has an active window. Every account
#                                     excluded from the pick says why on its own row.
#                                     Fetches LIVE numbers by default, and when a
#                                     stored token is stale spends one haiku token on
#                                     that account so the CLI rotates + persists the
#                                     credential itself. Rows the usage API 429s (it
#                                     limits per token, ~1/min, and live sessions poll
#                                     their own token) fall back to age-marked cached
#                                     numbers; a cached window that has ALREADY RESET
#                                     prints "expired", never its stale number.
#                                     Also warns when ~/.claude/.claude.json exists and
#                                     names a DIFFERENT account than ~/.claude.json,
#                                     the nested-config trap described above.
#                                     --no-refresh: fast path, cache only, no network.
#                                     --refresh:    accepted, no-op (now the default).
#                                     --json:       the same data machine-readably;
#                                                   every window carries remaining_pct
#                                                   AND used_pct (field order and names
#                                                   unchanged, only the RENDERED order
#                                                   leads with used), the weekly object
#                                                   additionally carries the binding
#                                                   limit's `kind` and `scope` (both null
#                                                   when the seven_day fallback was used /
#                                                   the binding limit is unscoped),
#                                                   plus `fresh`, true
#                                                   means "resets_at is null because the
#                                                   window has not started" (100/0), so a
#                                                   consumer never has to guess whether a
#                                                   null reset means fresh or unknown.
#                                                   Every published field above keeps its
#                                                   name; the camelCase view a phone
#                                                   renderer wants is ADDITIVE alongside
#                                                   it, top-level generatedAt +
#                                                   activeEmail, per account loggedIn /
#                                                   current / live / stale, per window
#                                                   usedPct / leftPct / resetsAt /
#                                                   resetsInSeconds (weekly, plus a
#                                                   `session` alias of five_hour), and
#                                                   recommendation.reason, the same
#                                                   one-line rationale the human view
#                                                   prints. stdout is ONE object and
#                                                   nothing else; every note and warning
#                                                   goes to stderr, and a run that cannot
#                                                   produce a usable object prints
#                                                   {"error":"…"} on stdout and exits 1,
#                                                   so a caller can parse either way.
#   rota failover switch-auto [--dry-run] [--quiet] [--new-only|--restart-idle] [--verbose] [--color|--no-color]
#                                     No-argument switch: pick the best OTHER pool-backed
#                                     account by the same rule `usage` recommends
#                                     (soonest weekly reset among accounts clearing the
#                                     health floor) and switch-all to it.
#                                     SELF-EXPLAINING BY DEFAULT: it prints the SAME
#                                     per-account picture `usage` prints, every
#                                     account's weekly + 5h windows in both polarities
#                                     (used first), the live/cached marker, and the
#                                     reason each row was skipped, then the decision
#                                     and its rationale, then acts. One command, no
#                                     "now go run `rota usage` to see why".
#                                     It is literally the same renderer
#                                     (render_usage_table + recommendation_text), so
#                                     the two surfaces cannot describe the pool
#                                     differently.
#                                     --quiet / -q: the old terse one-liner (the pick,
#                                     or the one-line refusal WITH its `rota usage`
#                                     pointer, since there is then no table to read
#                                     instead), for scripts that parse this output.
#                                     It also suppresses the PANES block, which the
#                                     default view prints AFTER the switch result:
#                                     swapping the shared credential does not reach into
#                                     a running session, so "N panes may still be on the
#                                     previous account, restart to adopt" is the next
#                                     action, not a footnote.
#                                     RESTARTING IDLE PANES IS THE DEFAULT (2026-08-12;
#                                     it was opt-in as --restart-idle before): after a
#                                     successful switch the panes that are safe to
#                                     restart are restarted so they pick the new account
#                                     up, `/quit`, wait for the shell, then
#                                     `claude --resume "<pane title>"`. --new-only opts
#                                     out: only NEW `claude` launches adopt the account.
#                                     --restart-idle is still accepted as the EXPLICIT
#                                     spelling of the default (a no-op alias, kept for
#                                     scripts and muscle memory); the one difference is
#                                     that only the explicit form diagnoses an
#                                     unreachable tmux out loud, the default stays
#                                     silent about it, so a laptop switch never nags
#                                     about a tmux session that was never there.
#                                     A pane that is
#                                     MID-WORK (its last lines show `esc to interrupt` or
#                                     `Compacting`) is SKIPPED, because killing a pane
#                                     during a tool call destroys that work; so is a pane
#                                     whose title reads back empty (`claude --resume ""`
#                                     drops it to a bare shell), and so is the pane the
#                                     command itself is running in. (Skipped mid-work
#                                     panes are not stranded: `pane-converge`, the
#                                     keeper runs it every tick, restarts them the
#                                     moment they go idle.) It is `--resume
#                                     "<name>"` and never `claude --continue`: --continue
#                                     resumes the newest conversation for the WORKING
#                                     DIRECTORY, and every pane is in ~/code, so it loads
#                                     the wrong one (seen 2026-08-06). Every pane gets a
#                                     result line, and `--dry-run` lists
#                                     what it would do without sending a keystroke.
#                                     IN BURN-DOWN MODE IT REFUSES TO SWITCH,
#                                     printing the same stay sentence `usage` prints,
#                                     and exiting 0, not an error, while the ACTIVE
#                                     account still has more than the exhaustion
#                                     threshold of weekly left. Under scarcity a bare
#                                     `rota switch` must not move you off headroom you
#                                     are still spending; name an account
#                                     (`rota switch work`) to force it anyway.
#                                     REFRESHES FIRST, through the same helper the
#                                     dashboard uses (ensure_fresh_usage), so the decision
#                                     is never made on a cache the run never tried to
#                                     replace. And when the refresh genuinely cannot land
#                                    , dead network, every stored token stale, the usage
#                                     API 429ing, it falls back to the last-good CACHED
#                                     numbers, says so on stderr, and still picks, instead
#                                     of dead-ending and forcing you to name an account by
#                                     hand (the 2026-08-05 defect: every row was a cache
#                                     from 2026-07-20, so every row was excluded as "no
#                                     LIVE numbers" and the switch that exists to spare
#                                     you the choice refused to choose). The health floor
#                                     and the soonest-weekly-reset preference are
#                                     unchanged, this is about the INPUT being fresh, and
#                                     about never wedging, not about the policy. A cached
#                                     window that has ALREADY RESET is still never scored:
#                                     its number was measured in a window that no longer
#                                     exists.
#   rota failover switch-all <label-substring> [--new-only|--restart-idle]
#                                     POINTER SWITCH (pool v2, 2026-08-11, see
#                                     the pool v2 design notes). Switching an
#                                     account no longer moves a single credential byte:
#                                     with the shim installed every session lives in its
#                                     own pool dir, so the shared ~/.claude credential
#                                     had NO reader and was pure single-use-refresh-token
#                                     risk. switch-all now:
#                                       1. resolves the target dir BY IDENTITY (the dir
#                                          whose .claude.json holds the target email,
#                                          the accounts-file mapping is verified, not
#                                          trusted; a stale map flags needs-reconcile),
#                                       2. refuses a husked/incomplete credential with
#                                          the one-browser-login command to fix it,
#                                       3. rewrites ~/.claude.json's oauthAccount (the
#                                          pointer every new shim launch resolves),
#                                       4. DELETES any ~/.claude/.credentials.json and
#                                          any shared Keychain item (both service-name
#                                          shapes; deletion works from a locked
#                                          keychain), idempotent hygiene, not a swap,
#                                       5. verifies by re-reading the claim + the target
#                                          dir's identity. No byte comparison, no usage
#                                          round trip, no `claude` subprocess.
#                                     Idle panes are restarted after the pointer moves
#                                     (DEFAULT since 2026-08-12), so they re-pin via the
#                                     shim; --new-only skips that (new launches only),
#                                     --restart-idle is the accepted no-op alias of the
#                                     default (and the spelling that diagnoses an
#                                     unreachable tmux out loud). Mid-work panes are
#                                     never restarted; pane-converge picks them up.
#                                     Tuning knobs: CLAUDE_FAILOVER_VERIFY_TRIES (5),
#                                     CLAUDE_FAILOVER_VERIFY_SLEEP (1s).
#   rota failover pane-converge [--dry-run]
#                                     Restart the idle panes whose claude process is
#                                     pinned (CLAUDE_CONFIG_DIR, via the same `ps eww`
#                                     walk the `billing now:` header uses) to a POOL dir
#                                     whose identity differs from the active claim in
#                                     ~/.claude.json, the panes a switch could NOT
#                                     restart because they were mid-work at the time.
#                                     Same safety rules as the switch restart (mid-work
#                                     and empty-title panes skipped, resume BY NAME,
#                                     never the calling pane); unpinned sessions and
#                                     non-pool pins (scratch / login capture) are never
#                                     touched. Prints one line per divergent pane and a
#                                     machine-readable summary line
#                                     (`pane-converge: restarted=N busy=M divergent=K`);
#                                     exit 0 always, a busy pane is a wait, not an
#                                     error. The pool keeper runs this every tick (step
#                                     4b, PANE_CONVERGE=0 disables), which is what makes
#                                     "a busy pane converges when it goes idle" true
#                                     without anyone remembering to re-run a switch.
#   rota failover reconcile [--apply]
#                                     Rewrite the accounts-file email→dir mapping FROM
#                                     the dirs' own identities (<dir>/.claude.json is
#                                     the only identity source; the accounts file is a
#                                     cache of it). Atomic (mktemp+mv), preserves
#                                     comment lines, appends an auto-fix comment with a
#                                     timestamp, never moves credential bytes. Bare
#                                     prints the proposed diff; --apply writes it. Exit
#                                     0 both ways; exit 4 when two dirs hold the SAME
#                                     identity (ambiguous, reported, nothing written).
#   rota failover normalize           When two pool dirs hold each other's accounts AND
#                                     no live process is pinned to either (checked via
#                                     `ps eww -ax`), swap the two dirs'
#                                     .credentials.json + .claude.json pairs back so
#                                     names match contents, then reconcile. Consumes the
#                                     normalize-pending record reconcile --apply writes
#                                     (a reconciled map can no longer show the crossed
#                                     pair), falling back to label-mismatch detection
#                                     for a stale map. Exit 3 with the pinned PIDs when
#                                     any live process holds either dir (the pending
#                                     record survives for the next try). Together with
#                                     adopt-shared these are the only code paths that
#                                     ever move credential files, same-filesystem
#                                     renames, only when provably no process holds the
#                                     chain in memory.
#   rota failover pool-init           Idempotent fresh-machine bootstrap (a laptop with
#                                     one shared ~/.claude login and no pool yet): read
#                                     the roster from the accounts file, create each
#                                     seat's config dir, and symlink settings.json/
#                                     commands/skills/plans/projects → ~/.claude/* (so
#                                     sessions share config + transcripts across
#                                     accounts). With NO accounts file it prints how to
#                                     create one (config/accounts.example is the
#                                     template) and exits 2. Creates and touches NO
#                                     credential.
#   rota failover roster              Print the roster (the accounts file), one
#                                     "email|dir" per line. Read-only; the pool
#                                     keeper's displaced-login detection consumes it.
#                                     Exits 2 when there is no accounts file yet.
#   rota failover adopt-shared
#                                     MOVE (never copy) the shared ~/.claude login into
#                                     its pool dir: requires ZERO live claude processes
#                                     (exit 3, an unpinned session holds the shared
#                                     chain in memory), resolves the pool dir from
#                                     ~/.claude.json's oauthAccount (run pool-init
#                                     first), refuses if that dir already holds a
#                                     complete credential (exit 4, twin chains husk
#                                     each other), and when the login lives ONLY in the
#                                     Keychain (no movable .credentials.json, or a
#                                     husk) refuses with exit 5 and prints the one
#                                     browser-login command into the pool dir instead.
#                                     Writes the identity into <dir>/.claude.json
#                                     (other keys preserved), keeps ~/.claude.json's
#                                     oauthAccount as the claim/pointer, and purges the
#                                     shared Keychain items so the moved file is the
#                                     only source.

set -euo pipefail

# Where this script lives; sibling rota-*.sh scripts and the repo's config/
# examples are found relative to it (through a symlink chain if any).
ROTA_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ⚠️ "WHICH SEAT IS NEXT" IS NOT ANSWERED IN THIS FILE ANY MORE. The deadline
# rule and the ordering around it live in rota-ranking.sh, sourced by this
# script AND by rota-keeper.sh, because the two used to hold the same rule
# separately and drifted apart the moment one of them learned something (see
# that file's header). Everything below still owns its own ELIGIBILITY floors.
#
# ⚠️ HARD FAIL, never a silent degrade. Without it the ranking calls below would
# be "command not found" halfway through a report, or worse, quietly skipped:
# a picker that has lost its ranking rule and says nothing is the exact failure
# this split exists to prevent. die() is not defined this early, so this is a
# plain printf + exit.
if [[ ! -r "$ROTA_LIB/rota-ranking.sh" ]]; then
  printf 'rota-engine.sh: %s/rota-ranking.sh is missing; this is an incomplete checkout (it holds the seat ranking, shared with rota-keeper.sh)\n' "$ROTA_LIB" >&2
  exit 1
fi
# shellcheck source=lib/rota-ranking.sh
. "$ROTA_LIB/rota-ranking.sh"

CFG_DIR="${CLAUDE_FAILOVER_HOME:-$HOME/.config/claude-failover}"
ACCOUNTS_FILE="$CFG_DIR/accounts"
STATE_FILE="$CFG_DIR/current"
USAGE_CACHE="$CFG_DIR/usage-cache.json"
USAGE_API="https://api.anthropic.com/api/oauth/usage"

# ── peers: boxes that hold a credential this one does not ────────────────────
# One ssh destination per line, `#` comments and blanks ignored. Empty/absent by
# default, which is exactly today's behaviour: no file, no peer, no ssh. See the
# peer-usage block above collect_usage for what is read and why no credential
# ever moves. ROTA_PEERS (space/comma separated) overrides the file, and being
# SET-BUT-EMPTY is a real answer ("no peers"), which is how the remote leg of a
# peer call switches the feature off on the box it lands on.
PEERS_FILE="$CFG_DIR/peers"
PEER_CACHE="$CFG_DIR/peer-usage-cache.json"
PEER_TTL="${ROTA_PEER_TTL:-90}"            # seconds a peer payload stays reusable
PEER_FAIL_TTL="${ROTA_PEER_FAIL_TTL:-300}" # …and how long a FAILED peer is left alone
PEER_TIMEOUT="${ROTA_PEER_TIMEOUT:-10}"    # ceiling on the whole peer STEP, all peers
# ⚠️ A KNOB IS SOMETHING A PERSON TYPED, so it is never trusted into arithmetic.
# `ROTA_PEER_TIMEOUT=10s` is the obvious thing to write for a duration and used to
# abort the whole command with `value too great for base`; `ROTA_PEER_TTL=abc`
# printed `unbound variable` on stderr every single run. A bad knob now falls back
# to its default SILENTLY, because a mistyped tuning value must never cost you the
# table. 10# forces base ten, or a well-meant `090` would be read as octal.
[[ "$PEER_TTL"      =~ ^[0-9]+$ ]] || PEER_TTL=90
[[ "$PEER_FAIL_TTL" =~ ^[0-9]+$ ]] || PEER_FAIL_TTL=300
[[ "$PEER_TIMEOUT"  =~ ^[0-9]+$ ]] || PEER_TIMEOUT=10
PEER_TTL=$((10#$PEER_TTL)); PEER_FAIL_TTL=$((10#$PEER_FAIL_TTL)); PEER_TIMEOUT=$((10#$PEER_TIMEOUT))
# ROTA_PEER_TIMEOUT=0 means the peer step is OFF, not "kill every dial the instant
# it starts". "No time at all for peers" only sensibly reads as "do not", and it
# gives a one-run kill switch (`ROTA_PEER_TIMEOUT=0 rota accounts`) that needs no
# config edit. A 0 that silently meant 1s would be a lie about what you asked for.
# 1 = this collection must not touch a peer; see resolve_shared_identity.
PEER_SKIP=0

# Health floor for the recommendation: an account needs real room left in BOTH
# windows to be worth switching ONTO, or you switch and wall again within the hour.
# It says nothing about the account you are already on, see EXHAUSTED_PCT.
MIN_WEEKLY="${CLAUDE_FAILOVER_MIN_WEEKLY:-20}"
MIN_SESSION="${CLAUDE_FAILOVER_MIN_SESSION:-10}"

# ── the SEAT's own lifecycle, which is not a quota fact ──────────────────────
#
# ⚠️ A CANCELLED SEAT IS STILL A LIVE SEAT UNTIL ITS END DATE, and this tool
# spent weeks implying otherwise. The operator, 2026-08-21: two seats had been
# cancelled and were still perfectly usable, with two or three more weekly
# refreshes each still to come, and every session was writing them off.
#
# The sessions were not being careless, the tool told them to. A cached weekly
# window that had already rolled rendered as "weekly window expired" under
# UNAVAILABLE. The string means "the number I have is stale, go and measure it".
# It READS as "this account is finished". Measured 2026-08-21 08:30, both
# cancelled seats showed exactly that while each still had roughly two more full
# weekly refreshes of quota that is already paid for.
#
# The facts needed to tell those apart already existed, billing.json has carried
# `status` and `ends` per seat since 2026-08-15, and this script simply never
# looked. It does now. Nothing here measures anything: the seat's lifecycle is
# the half no usage API exposes, which is that file's whole reason for existing
# ("THIS file holds the half that no API exposes").
#
# ⚠️ $CFG_DIR, NEVER A REPO-RELATIVE PATH. billing.json is per-machine state and
# lives beside the accounts file, exactly where rota-billing.sh reads it; the
# repo ships only config/billing.example.json, a template of made-up seats. A
# repo-relative default would consult that example on every box and answer
# "active, no end date" for every real seat while looking like it had read
# something.
BILLING_JSON="${CLAUDE_BILLING_JSON:-$CFG_DIR/billing.json}"

# ── the two modes ────────────────────────────────────────────────────────────
# The 20% floor above is the RIGHT rule in general and stays the default: leaving 12%
# unspent costs nothing when a fresh account is waiting, because you come back to it
# after it resets. It only becomes wrong under SCARCITY, the operator, 2026-08-06: "in
# general I agree with the 20% meaning, so that's the right rule in general. It's just
# that we are maxing out all the plans at the moment, and hence we don't have the
# luxury of switching away that early."
#
# So burn-down is a MODE, entered automatically when the pool has nowhere comfortable
# to go, not a permanent inversion of the floor:
#
#   COMFORTABLE_PCT  the weekly headroom the best OTHER account needs for the pool to
#                    count as roomy. At or above it → FLOOR mode (today's behaviour,
#                    untouched). Below it → BURN-DOWN mode.
#   EXHAUSTED_PCT    in burn-down mode, how little weekly the ACTIVE account has to be
#                    down to before we stop holding him on it (~98-100% used).
#
# CLAUDE_FAILOVER_MODE=floor|burn-down forces one regardless of the trigger; `auto`
# (the default) picks per the rule above.
COMFORTABLE_PCT="${CLAUDE_FAILOVER_COMFORTABLE:-50}"
EXHAUSTED_PCT="${CLAUDE_FAILOVER_EXHAUSTED:-2}"

# ── colour + layout primitives, defined ONCE ─────────────────────────────────
# Deliberately plain ANSI rather than tput: tput needs a usable TERM, which is
# absent under cron, in CI and with TERM=dumb, exactly the places `--color`
# exists to force codes ON. A `--color` that silently emitted nothing because
# terminfo was missing would be worse than having no flag at all.
#
# WHEN COLOUR IS EMITTED
#   auto (default)  stdout is a TTY and NO_COLOR is not set
#   --color         always, whatever stdout is (for `| less -R`, or a screenshot)
#   --no-color      never
# NO_COLOR is honoured for ANY value, empty included (https://no-color.org asks
# for "any value"), so `NO_COLOR= rota usage` is off too.
#
# With colour OFF every constant is the EMPTY STRING and paint() adds no reset,
# so the output is not merely uncoloured, it contains no escape bytes at all,
# which is what keeps a piped/redirected dashboard greppable and diffable.
COLOR_MODE="auto"          # auto | always | never
VERBOSE=0                  # --verbose/-v: slot paths, identity, full skip sentences
CLR_RESET=""; CLR_BOLD=""; CLR_DIM=""
CLR_RED=""; CLR_YELLOW=""; CLR_GREEN=""; CLR_CYAN=""
color_init() {
  local on=0
  case "$COLOR_MODE" in
    always) on=1 ;;
    never)  on=0 ;;
    *)      if [[ -t 1 ]] && [[ -z "${NO_COLOR+set}" ]]; then on=1; fi ;;
  esac
  if (( on )); then
    CLR_RESET=$'\033[0m'; CLR_BOLD=$'\033[1m'; CLR_DIM=$'\033[2m'
    CLR_RED=$'\033[31m'; CLR_YELLOW=$'\033[33m'; CLR_GREEN=$'\033[32m'; CLR_CYAN=$'\033[36m'
  else
    CLR_RESET=""; CLR_BOLD=""; CLR_DIM=""
    CLR_RED=""; CLR_YELLOW=""; CLR_GREEN=""; CLR_CYAN=""
  fi
}

# paint <sgr> <text>, no-op (and, crucially, no stray reset) when colour is off.
# Callers PAD FIRST and paint second: an escape sequence has zero display width
# but real byte length, so `printf '%-30s'` on an already-painted string pads by
# the wrong amount and the columns collapse.
paint() {
  if [[ -z "${1:-}" ]]; then printf '%s' "${2:-}"
  else printf '%s%s%s' "$1" "${2:-}" "$CLR_RESET"; fi
}

# The health colour of a "% LEFT" figure, the polarity the eye should act on:
# green ≥50 (plenty), yellow 20-49 (watch it), red <20 (at or under the floor).
pct_color() {
  local p="${1:-}"
  if [[ ! "$p" =~ ^[0-9]+$ ]]; then printf '%s' "$CLR_DIM"; return 0; fi
  if   (( p >= COMFORTABLE_PCT )); then printf '%s' "$CLR_GREEN"
  elif (( p >= MIN_WEEKLY ));      then printf '%s' "$CLR_YELLOW"
  else                                  printf '%s' "$CLR_RED"; fi
}

# A 15-cell meter whose FILLED portion is what is LEFT, so a full bar is good
# news. That is the opposite of a progress bar on purpose, and it is why the row
# leads with "% left": the bar and the leading number then say the same thing,
# and the "% used" figure the statusline reports rides right behind it.
BAR_CELLS=15
usage_bar() {  # usage_bar <left-pct>   ("" → an empty meter, for no data)
  local left="${1:-}" filled=0 i out=""
  if [[ "$left" =~ ^[0-9]+$ ]]; then
    filled=$(( (left * BAR_CELLS + 50) / 100 ))
    (( filled > BAR_CELLS )) && filled=$BAR_CELLS
    (( filled < 0 )) && filled=0
  fi
  # ${out} braced, NOT $out: bash 3.2 (macOS) reads the bytes of a following
  # multi-byte glyph as part of the parameter NAME, so `out="$out█"` dies with
  # "out\xe2\x96\x88: unbound variable" under set -u and the meter renders empty.
  for (( i = 0; i < filled; i++ )); do out="${out}█"; done
  for (( i = filled; i < BAR_CELLS; i++ )); do out="${out}░"; done
  printf '%s' "$out"
}

# Minimal JSON string escaping, deliberately jq-free: the one caller that MUST work
# without jq is the --json error object emitted when jq itself is the thing missing.
# Covers the escapes a die() message can realistically contain (backslash, quote, the
# three whitespace controls); anything more exotic never reaches it.
json_str() {
  local s="${1:-}"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

# `usage --json` promises a caller ONE parseable object on stdout, including when the
# run fails. Without this a missing accounts file or a missing jq answered with a bare
# English line on stderr, which a phone renderer can only report as "no data" with no
# reason. JSON_MODE is armed in main() before load_accounts, so even that early die
# comes back as {"error":…}. Exit stays non-zero either way.
JSON_MODE=0
die() {
  if (( JSON_MODE )); then
    printf '{"error":%s}\n' "$(json_str "$*")"
    exit 1
  fi
  printf 'rota-engine: %s\n' "$*" >&2; exit 1
}

# ~/-abbreviated path, for messages a human reads
tilde() { printf '%s' "${1/#$HOME/~}"; }

load_accounts() {
  [[ -f "$ACCOUNTS_FILE" ]] || die "no accounts file at $ACCOUNTS_FILE (run \`rota pool-init\` for instructions; config/accounts.example is the template)"
  LABELS=(); DIRS=()
  while IFS='|' read -r label dir; do
    [[ -z "${label// }" || "${label:0:1}" == "#" ]] && continue
    dir="${dir// }"
    # a leading ~/ in the accounts file means $HOME (the keeper and the guard expand it the same way)
    case "$dir" in "~/"*) dir="$HOME/${dir#\~/}" ;; esac
    LABELS+=("${label// }"); DIRS+=("$dir")
  done < "$ACCOUNTS_FILE"
  [[ ${#DIRS[@]} -ge 1 ]] || die "no accounts parsed from $ACCOUNTS_FILE"
}

current_index() {
  local i=0
  [[ -f "$STATE_FILE" ]] && i="$(cat "$STATE_FILE" 2>/dev/null || echo 0)"
  [[ "$i" =~ ^[0-9]+$ ]] || i=0
  (( i >= ${#DIRS[@]} )) && i=0
  echo "$i"
}
set_index() { mkdir -p "$CFG_DIR"; echo "$1" > "$STATE_FILE"; }

# ── credential + config primitives ───────────────────────────────────────────
# The config JSON for a CLAUDE_CONFIG_DIR. The default dir ~/.claude keeps its
# JSON one level UP as ~/.claude.json; an explicit CLAUDE_CONFIG_DIR keeps it
# inside the dir (verified: ~/.claude-pool/*/.claude.json all carry oauthAccount).
config_json() {
  local dir="$1"
  if [[ "$dir" == "$HOME/.claude" ]] || { [[ -d "$dir" ]] && [[ "$dir" -ef "$HOME/.claude" ]]; }; then
    printf '%s' "$HOME/.claude.json"
  else
    printf '%s' "$dir/.claude.json"
  fi
}

# .oauthAccount.emailAddress out of a config JSON FILE. Prints nothing when the file
# is missing or carries no oauthAccount.
json_email() {
  local f="${1:-}"
  [[ -f "$f" ]] || return 0
  if command -v jq >/dev/null 2>&1; then
    jq -r '.oauthAccount.emailAddress // empty' "$f" 2>/dev/null || true
  else
    # no jq: ~/.claude.json is one enormous line, so pull just this field out of it
    grep -o '"emailAddress" *: *"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/.*: *"//; s/"$//' || true
  fi
}

# Which account a config DIR believes it is logged in as, the same field Claude Code's
# own UI and ccstatusline read, resolved through config_json()'s ~/.claude → ~/.claude.json
# rule. Reads the file directly rather than shelling out to `claude auth status`, which
# renders this very field but costs a subprocess (see the header block).
config_email() { json_email "$(config_json "$1")"; }

# The nested-config trap, made visible. ~/.claude/.claude.json is a REAL file here: it
# is stale, nothing in this script writes it, and it is what ANY probe using
# CLAUDE_CONFIG_DIR=$HOME/.claude reads instead of the ~/.claude.json that actually
# governs sessions, the exact mistake this script used to make. Deleting it is still
# not ours to do (possibly a legacy artifact), so `usage` reports it, and now names
# `repair-nested`, which re-points it at the root file instead of removing it.
# Silent when the file is absent, carries no oauthAccount, or AGREES: only a real
# disagreement is worth a line.
NESTED_WARN=""
nested_config_warning() {
  NESTED_WARN=""
  local nested="$HOME/.claude/.claude.json" root="$HOME/.claude.json" ne re
  [[ -f "$nested" ]] || return 0
  [[ "$nested" -ef "$root" ]] && return 0
  ne="$(json_email "$nested")"
  [[ -n "$ne" ]] || return 0
  re="$(json_email "$root")"
  [[ "$ne" == "$re" ]] && return 0
  # shellcheck disable=SC2088  # "~/…" here is display text for a human, not a path
  NESTED_WARN="WARNING: a stale NESTED config exists, ~/.claude/.claude.json says ${ne}, while ~/.claude.json (the file real sessions use) says ${re:-no account}.
  Anything probing with CLAUDE_CONFIG_DIR=\$HOME/.claude reads the NESTED file and reports ${ne}, the wrong account. This script probes with CLAUDE_CONFIG_DIR unset.
  Run \`rota repair-nested\` to fix it: the stale copy is backed up and replaced by a symlink to ~/.claude.json, so that probe answers ${re:-the right account} and the two can never drift again."
}

# ── the nested-config trap, REPAIRED ─────────────────────────────────────────
# The fix for what nested_config_warning() reports, so a second box never has to be
# reasoned about from scratch. It is a SYMLINK, not a delete, for two reasons:
#   - the check above already encodes same-file (`-ef`) as the healthy state, so a link
#     makes a CLAUDE_CONFIG_DIR=$HOME/.claude probe answer CORRECTLY rather than not at
#     all (deleting the file would only convert a wrong answer into no answer);
#   - one file cannot drift from itself, so this cannot come back.
# Conservative by construction: it never invents a config, never removes the stale bytes
# without keeping them, and never touches anything when there is no valid root file to
# point at.

# Is this a file we can safely aim the nested config AT? A real parse when jq is here;
# otherwise the cheapest structural check that still rejects an empty or truncated file.
# Repairing TOWARD a broken root would be strictly worse than the drift it replaces.
valid_json_file() {
  local f="${1:-}"
  [[ -f "$f" && -s "$f" ]] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -e . "$f" >/dev/null 2>&1
  else
    [[ "$(head -c 1 "$f" 2>/dev/null)" == "{" ]]
  fi
}

# A backup path that does not exist yet. Same-day re-runs must not clobber the FIRST
# backup, that copy is the only surviving record of what the box drifted to.
nested_backup_path() {
  local base candidate n=2
  base="$HOME/.claude/.claude.json.stale-bak-$(date +%Y-%m-%d)"
  candidate="$base"
  while [[ -e "$candidate" || -L "$candidate" ]]; do
    candidate="$base.$n"; n=$((n + 1))
  done
  printf '%s' "$candidate"
}

# shellcheck disable=SC2016  # the single-quoted "$HOME" / `claude` below are literal
# display text, the probe shape and the command a human is meant to type, not expansions
repair_nested_config() {  # repair_nested_config [--dry-run]
  local dry=0
  case "${1:-}" in
    --dry-run|-n) dry=1 ;;
    "")           ;;
    *)            die "usage: rota failover repair-nested [--dry-run]" ;;
  esac
  local nested="$HOME/.claude/.claude.json" root="$HOME/.claude.json"
  local pfx=""; (( dry )) && pfx="[dry-run] would "

  # 1. nothing there → nothing to repair. -L as well as -e, so a dangling symlink at
  #    that path is still seen (it is a real trap: the probe fails rather than lying).
  if [[ ! -e "$nested" && ! -L "$nested" ]]; then
    printf 'nothing to repair, %s does not exist, so no probe can read a stale account from it.\n' \
      "$(tilde "$nested")"
    return 0
  fi

  # 2. already the same file → the healthy state nested_config_warning() tests for.
  #    Return BEFORE any backup: re-running this must not litter a repaired box.
  if [[ "$nested" -ef "$root" ]]; then
    local cur; cur="$(json_email "$root")"
    printf 'already healthy, %s already resolves to %s (%s). Nothing changed.\n' \
      "$(tilde "$nested")" "$(tilde "$root")" "${cur:-no account}"
    return 0
  fi

  # 3. nothing safe to point AT. Refuse loudly and leave the nested file untouched:
  #    a symlink to a missing or unparseable root is worse than a stale-but-readable
  #    config, and this verb must never be the thing that breaks a box.
  if ! valid_json_file "$root"; then
    printf 'refusing to repair: %s is %s.\n' "$(tilde "$root")" \
      "$([[ -e "$root" ]] && echo 'not valid JSON' || echo 'missing')" >&2
    printf 'There is nothing safe to point %s at, so it has been left exactly as it was. Log in once (`claude` → /login) to create a real root config, then re-run.\n' \
      "$(tilde "$nested")" >&2
    return 1
  fi

  local before after
  before="$(json_email "$nested")"
  after="$(json_email "$root")"
  printf '%s says %s; %s (the file real sessions use) says %s.\n' \
    "$(tilde "$nested")" "${before:-no account}" "$(tilde "$root")" "${after:-no account}"

  # 4. repair. Keep the stale bytes first, they are evidence, and the only way back.
  local backup=""
  if (( dry )); then
    backup="$(nested_backup_path)"
    printf '%sback up %s to %s, then replace it with a symlink to %s.\n' \
      "$pfx" "$(tilde "$nested")" "$(tilde "$backup")" "$(tilde "$root")"
    printf '%sleave a CLAUDE_CONFIG_DIR=$HOME/.claude probe reporting %s instead of %s.\n' \
      "$pfx" "${after:-no account}" "${before:-no account}"
    return 0
  fi
  # Only a regular file has bytes worth preserving; a dangling or foreign symlink has
  # nothing to copy, and cp would fail rather than help.
  if [[ -f "$nested" ]]; then
    backup="$(nested_backup_path)"
    cp -p "$nested" "$backup" || die "could not back up $(tilde "$nested"), nothing was changed"
    printf 'backed up the stale config to %s\n' "$(tilde "$backup")"
  fi
  rm -f "$nested"
  ln -s "$root" "$nested"

  # verify the trap now answers correctly, the same `-ef` the warning tests
  if [[ ! "$nested" -ef "$root" ]]; then
    if [[ -n "$backup" ]]; then
      rm -f "$nested"
      cp -p "$backup" "$nested"
      printf 'FAILED to repair: the symlink did not resolve to %s. Restored the original from %s; nothing was lost.\n' \
        "$(tilde "$root")" "$(tilde "$backup")" >&2
    else
      printf 'FAILED to repair: the symlink did not resolve to %s.\n' "$(tilde "$root")" >&2
    fi
    return 1
  fi
  printf '%s is now a symlink to %s, a CLAUDE_CONFIG_DIR=$HOME/.claude probe reports %s (was %s), and the two files can never drift again.\n' \
    "$(tilde "$nested")" "$(tilde "$root")" "${after:-no account}" "${before:-no account}"
}

# The stored OAuth access token for a config dir. Callers capture this into a local
# var used ONLY in an Authorization header, it is never printed, logged or cached.
cred_token() {
  local f="$1/.credentials.json"
  [[ -f "$f" ]] || return 0
  jq -r '.claudeAiOauth.accessToken // empty' "$f" 2>/dev/null || true
}

# How long ago the stored ACCESS token expired ("5d8h", "3h12m"), or nothing when it
# is still in date or the file carries no usable expiresAt. Reads one timestamp,
# never the token. An access token lives ~8h and only the CLI rotates it, so a seat
# nobody has run a session on since yesterday morning holds an expired one, and
# (measured on the pool host 2026-08-30, 150s of quiet before each probe, no live
# session on the seat) the usage API answers HTTP 429 to that token, not 401: 401
# is what a garbage token gets. The two callers below use this to tell "the vendor
# refused an expired token" from "panes are rate-limiting this token", which the
# HTTP code alone cannot.
cred_token_expired_ago() {  # cred_token_expired_ago <credentials-json-file>
  local f="${1:-}" exp now d
  [[ -f "$f" ]] || return 0
  exp="$(jq -r '.claudeAiOauth.expiresAt // empty' "$f" 2>/dev/null || true)"
  [[ "$exp" =~ ^[0-9]+$ ]] || return 0
  (( exp > 100000000000 )) && exp=$(( exp / 1000 ))
  now="$(date +%s)"
  (( now > exp )) || return 0
  d="$(human_delta $(( now - exp )))"
  printf '%s' "${d#in }"
}

# Does this dir hold a usable stored credential? `status` only needs the yes/no.
has_credential() {
  local f="$1/.credentials.json"
  [[ -f "$f" ]] || return 1
  if command -v jq >/dev/null 2>&1; then
    [[ -n "$(cred_token "$1")" ]]
  else
    grep -q '"accessToken"' "$f" 2>/dev/null
  fi
}

# ── the HUSK, and the one predicate that names it ────────────────────────────
# See "THE HUSK: WHAT ACTUALLY GUTS A POOL CREDENTIAL" in the header block for the
# 2026-08-07 incident and the controlled observation that identified the CLI's
# rejected-refresh cleanup, not any copy in this script, as the corrupting write.
#
# ONE predicate, used everywhere, and never an ad-hoc check. A credential is COMPLETE
# when it parses as JSON, `.claudeAiOauth.refreshToken` is a non-empty string, and
# `.claudeAiOauth.expiresAt` is present and non-null, exactly the three things the
# husk had lost. Nothing here ever prints, logs or captures a field's VALUE: jq
# answers true/false and its stdout goes to /dev/null.
cred_is_complete() {  # cred_is_complete <credentials-json-file>
  local f="${1:-}"
  [[ -f "$f" && -s "$f" ]] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -e '(.claudeAiOauth // {}) as $o
           | ($o.refreshToken | type == "string" and length > 0)
             and ($o | has("expiresAt")) and ($o.expiresAt != null)' \
       "$f" >/dev/null 2>&1
    return
  fi
  # no jq: the cheapest structural test that still rejects the husk. The KEY survives
  # a gutting, so the VALUE has to be seen as non-empty, a bare '"refreshToken"'
  # grep would call the husk complete, which is the whole bug.
  grep -q '"refreshToken"[[:space:]]*:[[:space:]]*"[^"]\{1,\}"' "$f" 2>/dev/null \
    && grep -q '"expiresAt"[[:space:]]*:[[:space:]]*[^n]' "$f" 2>/dev/null
}

# Would copying <src> over <dst> trade a good credential for a broken one? Every
# credential copy in this script asks this first and skips the copy when the answer is
# yes. DEFENCE IN DEPTH, not the fix for the 2026-08-07 incident, no copy here was
# ever proved to have gutted anything, and the header block says so. Deliberately
# narrow, it refuses ONLY the destructive direction
# (incomplete over complete), so a first-ever write, a husk-over-husk and every
# ordinary complete-over-anything copy behave exactly as they always have.
# Returns 0 = REFUSED (and says so in one line, on stderr), 1 = go ahead.
cred_overwrite_refused() {  # cred_overwrite_refused <src> <dst> <what>
  local src="${1:-}" dst="${2:-}" what="${3:-credential}"
  cred_is_complete "$src" && return 1
  cred_is_complete "$dst" || return 1
  printf 'REFUSED: %s at %s is complete and %s is not (no usable refresh token/expiry), kept the good copy, wrote nothing\n' \
    "$what" "$(tilde "$dst")" "$(tilde "$src")" >&2
  return 0
}

# Is this credential's REFRESH token still in date? The husk kept
# refreshTokenExpiresAt, and it is the only field that says whether a stored copy can
# still be revived at all, a stash whose refresh token has expired is not a rescue,
# it is a slower way to fail. Epoch is milliseconds in Claude Code's file; a value
# small enough to be seconds is accepted as seconds so this cannot misjudge either
# shape. Absent/unparseable = "cannot confirm it is in the future" = no.
cred_refresh_alive() {  # cred_refresh_alive <credentials-json-file>
  local f="${1:-}" exp now
  [[ -f "$f" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  exp="$(jq -r '.claudeAiOauth.refreshTokenExpiresAt // empty' "$f" 2>/dev/null || true)"
  [[ "$exp" =~ ^[0-9]+$ ]] || return 1
  (( exp > 100000000000 )) && exp=$(( exp / 1000 ))
  now="$(date +%s)"
  (( exp > now ))
}

# A husk backup path that does not exist yet. Same rule as nested_backup_path: a
# same-day re-run must never clobber the FIRST backup, that copy is the only
# surviving record of what the file was gutted to.
cred_backup_path() {  # cred_backup_path <credentials-json-file>
  local base candidate n=2
  base="$1.husk-bak-$(date +%Y-%m-%d)"
  candidate="$base"
  while [[ -e "$candidate" || -L "$candidate" ]]; do
    candidate="$base.$n"; n=$((n + 1))
  done
  printf '%s' "$candidate"
}

# Where switch-all stashes an account's credential on the way out.
cred_stash_path() { printf '%s' "$CFG_DIR/creds/$1.json"; }

# ── remembering a credential whose REFRESH was rejected ──────────────────────
# The loop this exists to prevent: the personal seat's stash and its pool copy hold the SAME dead
# credential, so "restore the pool copy from the stash" is followed immediately by a
# usage probe, a rejected refresh, and the CLI clearing the file again, a heal→gut
# cycle that rewrites the credential on every single run and never converges. Once we
# have watched a refresh be rejected, that exact credential is finished; nothing on
# this box can revive it but a fresh `/login`.
#
# The record is an IDENTITY, never content: bytes + mtime. That is enough to recognise
# the same credential in the stash (heal copies with `cp -p`, which preserves both),
# it changes the moment a real re-login writes new bytes, and it puts no part of a
# secret on disk or in a log.
cred_fingerprint() {  # cred_fingerprint <file> → "<bytes>:<mtime>", or nothing
  local f="${1:-}" sz mt
  [[ -f "$f" ]] || return 1
  sz="$(wc -c < "$f" 2>/dev/null | tr -d ' ')" || return 1
  mt="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)" || return 1
  [[ -n "$sz" && -n "$mt" ]] || return 1
  printf '%s:%s' "$sz" "$mt"
}

dead_refresh_marker() { printf '%s' "$CFG_DIR/dead-refresh/$1"; }

mark_refresh_dead() {  # mark_refresh_dead <label> <fingerprint>
  local m; m="$(dead_refresh_marker "$1")"
  [[ -n "${2:-}" ]] || return 0
  mkdir -p "$(dirname "$m")" 2>/dev/null || return 0
  printf '%s\n' "$2" > "$m" 2>/dev/null || true
}

# Is THIS file the credential we already watched a refresh be rejected for?
refresh_known_dead() {  # refresh_known_dead <label> <credentials-json-file>
  local m fp
  m="$(dead_refresh_marker "${1:-}")"
  [[ -f "$m" ]] || return 1
  fp="$(cred_fingerprint "${2:-}")" || return 1
  [[ -n "$fp" && "$fp" == "$(cat "$m" 2>/dev/null || true)" ]]
}

# ── self-heal on read ────────────────────────────────────────────────────────
# The other half of the 2026-08-07 incident: the good credential was sitting in the
# stash the whole time and nothing looked. So whenever a pool account's own copy is
# missing or gutted, and its stash IS complete with a refresh token still in date,
# the pool copy is restored from the stash and the run says so in one line. The husk
# is kept as <file>.husk-bak-<date> first, it is evidence, and the only way back.
#
# NEVER the shared ~/.claude: that file is rewritten by live sessions, so an
# "incomplete" read of it can simply be a torn read mid-rotation, and restoring a
# stash over a rotation in flight would break the very sessions this is meant to
# protect. The pool dirs have no such writer.
#
# THREE BRAKES, because an eager heal is worse than none (see the dead-refresh block
# above): at most ONCE per account per run; never from a stash whose refresh token has
# already expired; and never from a stash holding the exact credential whose refresh
# we have already watched be rejected. Together they make this converge instead of
# rewriting the same file forever.
# Returns 0 only when a heal actually happened.
#
# v2: shared slot is credential-free / stashes are read-only history, every
# call site is short-circuited (stage-1 review, 2026-08-12): a stash-restore
# moves credential bytes, which invariant 1 forbids, and restoring a stale
# credential is what arms the spurious nudge→husk cycle. Kept for reference,
# the brakes above document rules the keeper's nudge guards still live by.
HEAL_ATTEMPTED=""    # space-separated labels; a plain string, so no bash 4 needed
heal_pool_credential() {  # heal_pool_credential <pool-dir> <label>
  local dir="${1:-}" label="${2:-}"
  [[ -n "$dir" && -n "$label" && -d "$dir" ]] || return 1
  [[ "$dir" -ef "$HOME/.claude" ]] && return 1
  case " $HEAL_ATTEMPTED " in *" $label "*) return 1 ;; esac
  local pool="$dir/.credentials.json" stash
  stash="$(cred_stash_path "$label")"
  cred_is_complete "$pool" && return 1        # nothing wrong with it
  [[ "$pool" -ef "$stash" ]] && return 1
  cred_is_complete "$stash" || return 1
  cred_refresh_alive "$stash" || return 1
  # silent, deliberately: this is the steady state for an account waiting on a
  # re-login, and the UNAVAILABLE row already says so once per run. A line here would
  # repeat the same nag on every single `rota usage`.
  refresh_known_dead "$label" "$stash" && return 1
  HEAL_ATTEMPTED="$HEAL_ATTEMPTED $label"
  local bak=""
  if [[ -e "$pool" || -L "$pool" ]]; then
    bak="$(cred_backup_path "$pool")"
    cp -p "$pool" "$bak" 2>/dev/null || {
      printf 'note: %s looks gutted and a complete stash exists, but the husk could not be backed up, left it alone\n' \
        "$(tilde "$pool")" >&2
      return 1
    }
  fi
  # atomic: temp file in the SAME dir, then mv, a reader mid-write never sees
  # truncated JSON (the discipline sync_live_credential_back already uses).
  local tmp="$pool.failover-tmp.$$"
  if cp -p "$stash" "$tmp" 2>/dev/null && mv "$tmp" "$pool" 2>/dev/null; then
    chmod 600 "$pool" 2>/dev/null || true
    printf 'healed %s: its stored credential was %s, restored the complete copy from %s%s\n' \
      "$label" "$([[ -n "$bak" ]] && echo 'gutted' || echo 'missing')" "$(tilde "$stash")" \
      "$([[ -n "$bak" ]] && printf ' (husk kept at %s)' "$(tilde "$bak")")" >&2
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  printf 'note: could not restore %s from %s\n' "$(tilde "$pool")" "$(tilde "$stash")" >&2
  return 1
}

# Is this slot logged in? The rule `status` has published all along, factored out so
# `usage --json` publishes the SAME boolean rather than a second opinion: a usable
# stored credential, OR being the account that governs the shared ~/.claude, whose
# pool copy is allowed to be stale, because running sessions burn its single-use
# refresh tokens. Depends on resolve_shared_identity having run (SHARED_SLOT).
# Every Keychain item that can shadow the SHARED credential. macOS keys a config
# dir's credential to its own item, and the default dir has TWO possible names:
#
#   "Claude Code-credentials"                     legacy / unsuffixed
#   "Claude Code-credentials-<sha256($HOME/.claude) first 8 hex>"   current builds
#
# Both existed on the always-on box on 2026-08-09, and this function is the fix for an hour
# lost that night: the old code probed ONLY the unsuffixed name, so the hashed item
# (e8f692e9 for ~/.claude) shadowed the file unseen. `switch` reported "no Keychain
# item is shadowing it" while `claude auth status` kept naming the old account, and
# deleting the unsuffixed item changed nothing. Never narrow this back to one name.
shared_keychain_services() {
  printf '%s\n' "Claude Code-credentials"
  local h
  h="$(printf '%s' "$HOME/.claude" | shasum -a 256 | cut -c1-8)"
  [[ -n "$h" ]] && printf '%s\n' "Claude Code-credentials-$h"
}

# Keep those items in lockstep with the file, and when the login keychain is
# locked, REMOVE them rather than leaving a stale item to govern.
#
# Why removal is the right fallback, and why it works: `add-generic-password -U`
# must unlock the keychain to write a value, which a tmux/SSH security session
# cannot do ("User interaction is not allowed"). `delete-generic-password` needs
# no unlock and succeeds there, verified on the always-on box, 2026-08-09. Deleting is safe
# and self-healing: the CLI then reads $CLAUDE_CONFIG_DIR/.credentials.json, which
# is exactly the file `switch` owns, and re-creates the item at the next GUI
# /login. The old behaviour instead told the user to go find a GUI Terminal, which
# on a headless box is a dead end (Terminal automation is not permitted there).
#
# Duplicates under one service name are real, deleting one on 2026-08-09 left a
# second behind, so each name is drained in a loop rather than deleted once.
#
# Echoes exactly one of: updated | removed | absent | stuck
# v2: shared slot is credential-free, the switch path no longer syncs a
# credential INTO the Keychain, so nothing calls this any more (the delete-only
# purge_shared_keychain below is what v2 uses). Kept, not removed: the hermetic
# suite exercises it and removal buys nothing.
sync_shared_keychain() {  # sync_shared_keychain <credentials-file>
  local cred="$1" svc found=0 updated=0 removed=0 stuck=0
  while IFS= read -r svc; do
    [[ -n "$svc" ]] || continue
    security find-generic-password -s "$svc" -a "$USER" >/dev/null 2>&1 || continue
    found=1
    if security add-generic-password -U -s "$svc" -a "$USER" -w "$(< "$cred")" >/dev/null 2>&1; then
      updated=1
      continue
    fi
    # BOUNDED on purpose. Duplicates under one service name are a handful at
    # most, and an unbounded `while security delete …` spins forever against any
    # `security` that always exits 0, which is exactly what the test stub does.
    local drained=0 attempt=0
    while (( attempt < 8 )) && security delete-generic-password -s "$svc" -a "$USER" >/dev/null 2>&1; do
      drained=1
      attempt=$((attempt + 1))
    done
    if (( drained )); then removed=1; else stuck=1; fi
  done < <(shared_keychain_services)
  if (( stuck )); then printf 'stuck'
  elif (( removed )); then printf 'removed'
  elif (( updated )); then printf 'updated'
  elif (( found )); then printf 'stuck'
  else printf 'absent'; fi
}

# ── pool v2: the shared slot is credential-free ──────────────────────────────
# Delete-only sibling of sync_shared_keychain: under the pointer-switch design
# the shared ~/.claude must hold NO credential, so any Keychain item under
# either service name is stale by definition and gets REMOVED, the same
# bounded drain sync_shared_keychain uses (duplicates under one name are real,
# and deletion works from a locked keychain where an update does not).
# Echoes exactly one of: removed | absent | stuck
purge_shared_keychain() {
  local svc found=0 removed=0 stuck=0 drained attempt
  while IFS= read -r svc; do
    [[ -n "$svc" ]] || continue
    security find-generic-password -s "$svc" -a "$USER" >/dev/null 2>&1 || continue
    found=1
    drained=0; attempt=0
    while (( attempt < 8 )) && security delete-generic-password -s "$svc" -a "$USER" >/dev/null 2>&1; do
      drained=1
      attempt=$((attempt + 1))
    done
    if (( drained )); then removed=1; else stuck=1; fi
  done < <(shared_keychain_services)
  if (( stuck )); then printf 'stuck'
  elif (( removed )); then printf 'removed'
  elif (( found )); then printf 'removed'
  else printf 'absent'; fi
}

# ── live pinned processes (pool v2) ──────────────────────────────────────────
# `ps eww -ax` prints each process's environment after its argv, so a claude
# process pinned to a pool dir shows CLAUDE_CONFIG_DIR=<dir> on its line. That
# is the one signal that says "this chain is held in memory right now", which
# gates normalize (never move a pair a process holds) and feeds the `billing
# now:` header. CLAUDE_FAILOVER_PS_CMD is the test hook: an executable whose
# stdout replaces the ps output (the hermetic suite feeds fixtures through it).
pool_ps() {
  if [[ -n "${CLAUDE_FAILOVER_PS_CMD:-}" ]]; then
    "${CLAUDE_FAILOVER_PS_CMD}" 2>/dev/null || true
  else
    ps eww -ax 2>/dev/null || true
  fi
}

# Every CLAUDE_CONFIG_DIR a live *claude* process is pinned to, one per line
# with its pid: "<pid> <dir>". The command test keys on the COMMAND column
# (field 5 of `PID TT STAT TIME COMMAND...`), never on a bare /claude/ match,
# a pinned shell also carries the env var, and the string "claude" appears
# inside every pool path.
live_claude_pins() {
  pool_ps | awk '
    NR == 1 && $1 == "PID" { next }
    {
      cmd = $5; sub(".*/", "", cmd)
      if (cmd != "claude" && cmd != "claude.exe") next
      for (i = 6; i <= NF; i++)
        if ($i ~ /^CLAUDE_CONFIG_DIR=/) {
          sub("CLAUDE_CONFIG_DIR=", "", $i)
          print $1, $i
        }
    }' 2>/dev/null || true
}

# The pids (space-joined) of live claude processes pinned to <dir>, empty when
# none. Compares resolved paths when both exist so a symlinked spelling of the
# same dir still counts as pinned.
pids_pinned_to_dir() {  # pids_pinned_to_dir <dir>
  local want="${1:-}" pid dir out=""
  [[ -n "$want" ]] || return 0
  while read -r pid dir; do
    [[ -n "$pid" && -n "$dir" ]] || continue
    if [[ "$dir" == "$want" ]] || { [[ -d "$dir" && -d "$want" ]] && [[ "$dir" -ef "$want" ]]; }; then
      out="${out:+$out }$pid"
    fi
  done < <(live_claude_pins)
  printf '%s' "$out"
}

# ── reconcile: the accounts file is a CACHE of dir identities (pool v2) ──────
# The 2026-08-11 incident this fixes: a /login inside a pinned pane wrote the
# work account into the `personal` pool dir; the map never noticed, and every
# "personal" launch silently billed the work seat. The dirs' own .claude.json files are the
# only identity source, so this rewrites the map's EMAIL column from them,
# atomically, preserving comments, never touching a credential byte.
#   bare     print the proposed diff (exit 0, writes nothing)
#   --apply  write it (exit 0)
#   exit 4   two dirs hold the SAME identity, ambiguous, reported, no write
cmd_reconcile() {
  local apply=0 a
  for a in "$@"; do
    case "$a" in
      --apply) apply=1 ;;
      *) die "usage: rota failover reconcile [--apply]" ;;
    esac
  done
  # --apply mutates shared pool state → the mutation lock (bare is read-only).
  # Reentrant: normalize's closing reconcile runs under its caller's lock.
  if (( apply )); then
    pool_mutate_acquire || pool_mutate_busy_die "reconcile"
  fi

  # identities, per accounts-file slot; ambiguity = one identity in two dirs
  local i j changes=0
  local RID=()
  for i in "${!DIRS[@]}"; do
    RID[i]="$(config_email "${DIRS[$i]}")"
  done
  for i in "${!DIRS[@]}"; do
    [[ -n "${RID[$i]}" ]] || continue
    for (( j = i + 1; j < ${#DIRS[@]}; j++ )); do
      if [[ "${RID[$i]}" == "${RID[$j]}" ]]; then
        printf 'reconcile: AMBIGUOUS, %s and %s BOTH hold %s. Nothing was written.\n' \
          "$(tilde "${DIRS[$i]}")" "$(tilde "${DIRS[$j]}")" "${RID[$i]}" >&2
        printf 'Two dirs with one identity means a copy happened somewhere; fix by re-logging one of them in (CLAUDE_CONFIG_DIR=<dir> claude → /login), then re-run.\n' >&2
        exit 4
      fi
    done
    [[ "${RID[$i]}" != "${LABELS[$i]}" ]] && changes=$((changes + 1))
  done

  # ── CROSSED PAIRS must be recorded BEFORE the map is rewritten ─────────────
  # (stage-1 review, 2026-08-12). normalize's own detection compares dir
  # identities against the accounts-file labels, but this very verb rewrites
  # those labels to match the dirs, which destroys the evidence: run reconcile
  # first (as the keeper, the shim flag and cred-guard all do) and normalize
  # would report "no swapped pair" forever while ~/.claude-pool/personal kept
  # holding the work seat. So a pair of dirs holding each other's CURRENT labels is
  # written to $CFG_DIR/normalize-pending before the rewrite; normalize
  # consumes it. Line shape (stage-2 review, 2026-08-12, fingerprints added):
  #
  #   <dirA>|<idA>|<dirB>|<idB>|<fpA>|<fpB>
  #
  # where fpX is cred_fingerprint (size:mtime, the dead-refresh markers'
  # exact shape, and mv/rename preserves both) of that dir's
  # .credentials.json AT RECORD TIME, "-" when the file is absent. The
  # fingerprints are what let the replay prove, per file, that a credential
  # has not moved since the record was written, without them a replay after
  # a partial swap re-ran the FULL swap and inverted the half that had
  # already landed (permanent invisible cross-billing).
  #
  # RECONCILE_SUPPRESS_PENDING=1 is set ONLY by normalize around its own
  # closing reconcile: at that instant the map still carries the pre-swap
  # labels, so the just-fixed pair reads as freshly crossed and would be
  # re-recorded, and the next normalize would dutifully swap the now-correct
  # dirs BACK. The one reconcile that runs mid-normalize must not record.
  local PENDING_LINES=()
  if [[ "${RECONCILE_SUPPRESS_PENDING:-0}" != "1" ]]; then
    local fpa fpb
    for i in "${!DIRS[@]}"; do
      [[ -n "${RID[$i]}" && "${RID[$i]}" != "${LABELS[$i]}" ]] || continue
      for (( j = i + 1; j < ${#DIRS[@]}; j++ )); do
        if [[ "${RID[$i]}" == "${LABELS[$j]}" && "${RID[$j]:-}" == "${LABELS[$i]}" ]]; then
          fpa="$(cred_fingerprint "${DIRS[$i]}/.credentials.json" 2>/dev/null || true)"
          fpb="$(cred_fingerprint "${DIRS[$j]}/.credentials.json" 2>/dev/null || true)"
          PENDING_LINES+=("${DIRS[$i]}|${RID[$i]}|${DIRS[$j]}|${RID[$j]}|${fpa:--}|${fpb:--}")
        fi
      done
    done
  fi

  if (( changes == 0 )); then
    printf 'reconcile: accounts file already matches the dir identities, nothing to do.\n'
    (( apply )) && rm -f "$CFG_DIR/needs-reconcile" 2>/dev/null || true
    return 0
  fi

  # Rebuild the file TEXTUALLY: comments and blank lines pass through
  # untouched, mapping lines get their email column replaced by the identity
  # the dir actually holds (a dir with no identity keeps its old label, there
  # is nothing better to write).
  local tmp
  tmp="$(mktemp "$ACCOUNTS_FILE.reconcile.XXXXXX")" || die "reconcile: mktemp failed"
  local line label dir sl sd
  while IFS= read -r line || [[ -n "$line" ]]; do
    label="${line%%|*}"; dir="${line#*|}"
    sl="${label//[$' \t\r']/}"
    if [[ -z "$sl" || "${sl:0:1}" == "#" || "$line" != *"|"* ]]; then
      printf '%s\n' "$line" >> "$tmp"
      continue
    fi
    sd="${dir// }"
    # find the slot this line loaded into (label+dir pair), take its identity
    local new="$sl"
    for i in "${!DIRS[@]}"; do
      if [[ "${LABELS[$i]}" == "$sl" && "${DIRS[$i]}" == "$sd" ]]; then
        [[ -n "${RID[$i]}" ]] && new="${RID[$i]}"
        break
      fi
    done
    printf '%s|%s\n' "$new" "$sd" >> "$tmp"
  done < "$ACCOUNTS_FILE"
  printf '# auto-reconciled by rota reconcile at %s, mapping rewritten from dir identities (<dir>/.claude.json)\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$tmp"

  if (( ! apply )); then
    printf 'reconcile: the accounts file no longer matches what the dirs hold. Proposed rewrite:\n\n'
    diff -u "$ACCOUNTS_FILE" "$tmp" || true
    printf '\nApply with: rota reconcile --apply\n'
    if [[ ${#PENDING_LINES[@]} -gt 0 ]]; then
      printf 'NOTE: this is a CROSSED PAIR (two dirs hold each other'\''s accounts). --apply will also record it in %s so `normalize` can swap the files back at the next process-free window.\n' \
        "$(tilde "$CFG_DIR/normalize-pending")"
    fi
    rm -f "$tmp"
    return 0
  fi

  # the pending record goes down FIRST: once the mv below lands, the labels
  # match the dirs and nothing can re-derive which pair was crossed
  if [[ ${#PENDING_LINES[@]} -gt 0 ]]; then
    mkdir -p "$CFG_DIR"
    printf '%s\n' "${PENDING_LINES[@]}" > "$CFG_DIR/normalize-pending"
    printf 'reconcile: crossed pair recorded in %s, `normalize` (or the keeper) swaps the files back once both dirs are process-free.\n' \
      "$(tilde "$CFG_DIR/normalize-pending")"
  fi

  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$ACCOUNTS_FILE" || { rm -f "$tmp"; die "reconcile: could not write $ACCOUNTS_FILE"; }
  rm -f "$CFG_DIR/needs-reconcile" 2>/dev/null || true
  for i in "${!DIRS[@]}"; do
    [[ -n "${RID[$i]}" && "${RID[$i]}" != "${LABELS[$i]}" ]] \
      && printf 'reconciled: %s now maps %s (was %s)\n' "$(tilde "${DIRS[$i]}")" "${RID[$i]}" "${LABELS[$i]}"
  done
  return 0
}

# ── one-shot operator notification (pool v2, stage-2 review) ─────────────────
# The failover leaf's own notify path, mirroring cred-guard's mechanism
# (osascript display notification behind a state-change dedupe file): notify
# only when the message for a key CHANGES, never on every run. Used by the
# normalize replay refusal and the post-swap pin check, states a human must
# see once, not once per keeper tick.
pool_notify_once() {  # pool_notify_once <key> <message>
  local key="${1:-}" msg="${2:-}" state prev=""
  state="$CFG_DIR/notified-$key"
  [[ -f "$state" ]] && prev="$(cat "$state" 2>/dev/null || true)"
  [[ "$prev" == "$msg" ]] && return 0
  mkdir -p "$CFG_DIR" 2>/dev/null || return 0
  printf '%s' "$msg" > "$state" 2>/dev/null || true
  if [[ -z "${CLAUDE_FAILOVER_NO_NOTIFY:-}" ]] && command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"${msg//\"/\\\"}\" with title \"Claude account pool\"" \
      >/dev/null 2>&1 || true
  fi
  return 0
}

# ── the shared MUTATION lock (pool v2, stage-2 review) ───────────────────────
# One mkdir lock around every verb that mutates shared pool state, reconcile
# --apply, normalize, adopt-shared, whoever the caller is (interactive, the
# keeper's tick, cred-guard's escalation). mkdir is the atomic claim;
# reentrant within one process (normalize's own closing reconcile must not
# deadlock on the lock its caller holds). A lock older than
# CLAUDE_FAILOVER_LOCK_STALE_SECS (1800) is a crashed run's and is broken by
# rm + re-mkdir, the re-mkdir is the claim, so two takers cannot both win.
# Busy after the short retry → the verb exits 7 ("mutation lock held"): the
# keeper logs-and-skips on 7, an interactive caller reads the message.
POOL_MUTATE_LOCK=""   # set from CFG_DIR at first acquire (CFG_DIR is final by then)
POOL_MUTATE_HELD=0
pool_mutate_acquire() {
  (( POOL_MUTATE_HELD )) && return 0
  POOL_MUTATE_LOCK="$CFG_DIR/pool-mutate.lock"
  mkdir -p "$CFG_DIR" 2>/dev/null || true
  local tries="${CLAUDE_FAILOVER_LOCK_TRIES:-3}" i=0 now mt age
  while ! mkdir "$POOL_MUTATE_LOCK" 2>/dev/null; do
    now="$(date +%s)"
    mt="$(stat -f %m "$POOL_MUTATE_LOCK" 2>/dev/null || stat -c %Y "$POOL_MUTATE_LOCK" 2>/dev/null || echo "$now")"
    age=$(( now - mt ))
    if (( age > ${CLAUDE_FAILOVER_LOCK_STALE_SECS:-1800} )); then
      printf 'pool-mutate: breaking a stale lock (%ss old)\n' "$age" >&2
      rm -rf "$POOL_MUTATE_LOCK" 2>/dev/null || true
      # fall through: the next mkdir is the atomic re-claim
    else
      i=$((i + 1))
      (( i >= tries )) && return 1
      sleep "${CLAUDE_FAILOVER_LOCK_RETRY_SLEEP:-1}"
    fi
  done
  printf '%s\n' "$$" > "$POOL_MUTATE_LOCK/pid" 2>/dev/null || true
  POOL_MUTATE_HELD=1
  # this trap is the leak-guard: a die() mid-verb must not wedge every future
  # mutation behind a dead lock (the stale-break above is the backstop, not
  # the plan). No other EXIT trap exists in this script.
  trap 'rm -rf "$POOL_MUTATE_LOCK" 2>/dev/null || true' EXIT
  return 0
}

# the message + exit every mutating verb uses when the lock stays busy
pool_mutate_busy_die() {  # pool_mutate_busy_die <verb>
  printf '%s: the pool mutation lock is held (%s), another reconcile/normalize/adopt-shared is mid-flight. Re-run in a moment; the keeper simply retries next tick.\n' \
    "${1:-pool-mutate}" "$(tilde "$CFG_DIR/pool-mutate.lock")" >&2
  exit 7
}

# ── normalize: put swapped dir CONTENTS back where their names say (pool v2) ─
# reconcile makes the MAP truthful; normalize makes the DIRS truthful again
# when two of them hold each other's accounts (the shape a crossed /login
# leaves behind). It is the only routine code path that ever moves credential
# files (adopt-shared, the one-time bootstrap, is the other): pairs move by
# same-filesystem rename, and only after proving, via live_claude_pins, that
# no running process holds either chain in memory (a live process would
# refresh its chain and husk the moved copy).
#
# TWO detection paths (stage-1 review, 2026-08-12):
#   1. $CFG_DIR/normalize-pending, written by reconcile --apply BEFORE it
#      rewrites the map. After that rewrite the labels match the dirs by
#      construction, so the label-mismatch detection below can never see the
#      crossed pair again; the pending record is the surviving evidence.
#      REPLAYED UNDER FINGERPRINT PROOF (stage-2 review): every file moves
#      only when it provably has not moved since the record was written.
#   2. label-mismatch (the original detection), still covers the stale-map
#      case where normalize runs before any reconcile has.

# The physical swap, shared by both paths. Exits 3 (pending record untouched)
# when a live process is pinned to either dir. Extra file args narrow the swap
# to just those files (the replay's complete-the-missing-half case); default
# is the full .credentials.json + .claude.json pair.
normalize_swap_pair() {  # normalize_swap_pair <dirA> <dirB> <idA-now> <idB-now> [file ...]
  local da="${1:-}" db="${2:-}" ida="${3:-}" idb="${4:-}"
  shift 4 || true
  local files=("$@")
  [[ ${#files[@]} -gt 0 ]] || files=(.credentials.json .claude.json)
  local pins_a pins_b
  pins_a="$(pids_pinned_to_dir "$da")"
  pins_b="$(pids_pinned_to_dir "$db")"
  if [[ -n "$pins_a" || -n "$pins_b" ]]; then
    local where=""
    [[ -n "$pins_a" ]] && where="$(tilde "$da") (pids $pins_a)"
    [[ -n "$pins_b" ]] && where="${where:+$where and }$(tilde "$db") (pids $pins_b)"
    printf 'normalize: REFUSED, a live claude process is pinned to %s. Moving the pair out from under it would husk the chain it holds in memory.\n' \
      "$where" >&2
    printf 'Quit those sessions (or wait for the keeper to catch a process-free window), then re-run.\n' >&2
    exit 3
  fi

  printf 'normalize: %s holds %s and %s holds %s, swapping %s back.\n' \
    "$(tilde "$da")" "$ida" "$(tilde "$db")" "$idb" "${files[*]}"
  local f fa fb ta tb
  for f in "${files[@]}"; do
    fa="$da/$f"; fb="$db/$f"
    ta="$fa.normalize-tmp.$$"; tb="$fb.normalize-tmp.$$"
    # same filesystem (both under the pool root), so each mv is a rename; the
    # three-step shuffle means no moment where one path holds both files
    if [[ -f "$fa" && -f "$fb" ]]; then
      mv "$fa" "$ta" && mv "$fb" "$fa" && mv "$ta" "$fb" \
        || die "normalize: swap of $f failed midway, inspect $(tilde "$da") and $(tilde "$db") (a *.normalize-tmp.* file holds the displaced copy; the pending record makes the next run recover it)"
    elif [[ -f "$fa" ]]; then
      mv "$fa" "$fb" || die "normalize: could not move $(tilde "$fa")"
    elif [[ -f "$fb" ]]; then
      mv "$fb" "$fa" || die "normalize: could not move $(tilde "$fb")"
    fi
    rm -f "$ta" "$tb" 2>/dev/null || true
  done

  # ── post-swap pin re-check (stage-2 review, finding 2) ─────────────────────
  # The pre-gate above can pass during a shim launch's RESOLUTION window: the
  # shim only exports CLAUDE_CONFIG_DIR at exec time, so a launch in flight is
  # invisible to ps for up to a few seconds and can land on a dir whose pair
  # was just swapped. No cheap way to close the race, but detecting it is
  # cheap and honest: one more ps pass, and a pin that appeared names itself.
  local post_a post_b
  post_a="$(pids_pinned_to_dir "$da")"
  post_b="$(pids_pinned_to_dir "$db")"
  if [[ -n "$post_a" || -n "$post_b" ]]; then
    local pwhere=""
    [[ -n "$post_a" ]] && pwhere="$(tilde "$da") (pids $post_a)"
    [[ -n "$post_b" ]] && pwhere="${pwhere:+$pwhere and }$(tilde "$db") (pids $post_b)"
    printf 'normalize: WARNING, a claude process pinned to %s appeared DURING the swap (a shim launch resolving while we moved the pair). That session loaded whichever files were in place at its exec; restart it to be sure it holds the right chain.\n' \
      "$pwhere" >&2
    pool_notify_once "normalize-race" "A claude session started during a pool normalize ($pwhere), restart that session so it picks up the right account."
  fi
  return 0
}

# drop normalize-pending's CONSUMED first line, keep any further pairs
clear_pending_head() {  # clear_pending_head <pending-file>
  local pf="${1:-}" rest
  rest="$(tail -n +2 "$pf" 2>/dev/null || true)"
  if [[ -n "$rest" ]]; then printf '%s\n' "$rest" > "$pf"
  else rm -f "$pf"; fi
}

cmd_normalize() {
  [[ $# -eq 0 ]] || die "usage: rota failover normalize"
  pool_mutate_acquire || pool_mutate_busy_die "normalize"
  local pending="$CFG_DIR/normalize-pending"

  # ── path 1: the pending record reconcile left behind ───────────────────────
  if [[ -f "$pending" ]]; then
    local pl pda pida pdb pidb pfpa pfpb
    pl="$(head -1 "$pending" 2>/dev/null || true)"
    IFS='|' read -r pda pida pdb pidb pfpa pfpb <<<"$pl"
    if [[ -z "$pda" || -z "$pida" || -z "$pdb" || -z "$pidb" || -z "$pfpa" || -z "$pfpb" ]]; then
      printf 'normalize: malformed/fingerprint-less %s, dropping it and falling back to label-mismatch detection.\n' \
        "$(tilde "$pending")" >&2
      rm -f "$pending"
    else
      # 0. RECOVER stranded *.normalize-tmp.* leftovers before judging state
      #    (stage-2 review, finding 1). A crash mid-shuffle leaves one dir's
      #    credential parked under a tmp name, mv preserves size+mtime, so
      #    the recorded fingerprint identifies WHOSE credential a leftover is
      #    and where it belongs. Recovery restores the file, then this run
      #    still REFUSES: a run that had to recover must not also mutate; the
      #    next run judges the (now clean) state and completes.
      local recovered=0 tf tfp
      for tf in "$pda"/.credentials.json.normalize-tmp.* "$pdb"/.credentials.json.normalize-tmp.*; do
        [[ -f "$tf" ]] || continue
        tfp="$(cred_fingerprint "$tf" 2>/dev/null || true)"
        if [[ -n "$tfp" && "$tfp" == "$pfpa" && ! -e "$pda/.credentials.json" ]]; then
          mv "$tf" "$pda/.credentials.json" && recovered=1 \
            && printf 'normalize: recovered %s from a stranded swap temp (%s)\n' \
                 "$(tilde "$pda/.credentials.json")" "$(basename "$tf")" >&2
        elif [[ -n "$tfp" && "$tfp" == "$pfpb" && ! -e "$pdb/.credentials.json" ]]; then
          mv "$tf" "$pdb/.credentials.json" && recovered=1 \
            && printf 'normalize: recovered %s from a stranded swap temp (%s)\n' \
                 "$(tilde "$pdb/.credentials.json")" "$(basename "$tf")" >&2
        fi
      done
      # identity leftovers carry their identity IN the file, restore to the
      # dir whose recorded identity matches, when that dir's file is absent
      local tfe
      for tf in "$pda"/.claude.json.normalize-tmp.* "$pdb"/.claude.json.normalize-tmp.*; do
        [[ -f "$tf" ]] || continue
        tfe="$(json_email "$tf")"
        if [[ -n "$tfe" && "$tfe" == "$pida" && ! -e "$pda/.claude.json" ]]; then
          mv "$tf" "$pda/.claude.json" && recovered=1 \
            && printf 'normalize: recovered %s from a stranded swap temp\n' "$(tilde "$pda/.claude.json")" >&2
        elif [[ -n "$tfe" && "$tfe" == "$pidb" && ! -e "$pdb/.claude.json" ]]; then
          mv "$tf" "$pdb/.claude.json" && recovered=1 \
            && printf 'normalize: recovered %s from a stranded swap temp\n' "$(tilde "$pdb/.claude.json")" >&2
        fi
      done
      if (( recovered )); then
        printf 'normalize: REFUSING to continue in the same run that had to recover an interrupted swap, inspect %s and %s if you like; the pending record is kept and the next run (or keeper tick) completes from the clean state.\n' \
          "$(tilde "$pda")" "$(tilde "$pdb")" >&2
        pool_notify_once "normalize-recovered" "An interrupted pool swap was recovered ($(tilde "$pda") / $(tilde "$pdb")), normalize completes on its next run."
        exit 6
      fi

      # 1. JUDGE, per file, against the record. A file moves ONLY when it
      #    provably has not moved since the record was written.
      local cur_a cur_b fa_now fb_now cred_state id_state
      cur_a="$(config_email "$pda")"; cur_b="$(config_email "$pdb")"
      fa_now="$(cred_fingerprint "$pda/.credentials.json" 2>/dev/null || true)"; fa_now="${fa_now:--}"
      fb_now="$(cred_fingerprint "$pdb/.credentials.json" 2>/dev/null || true)"; fb_now="${fb_now:--}"

      # ── REFRESH-TOLERANT fingerprints (keeper polish, 2026-08-12 live) ─────
      # Live evidence (keeper.log 09:02→09:32): the record froze fingerprints
      # at record time; keepalive nudges + live sessions then LEGITIMATELY
      # rotated the files in place, and every later tick refused the replay as
      # "credentials: MISMATCH" forever. A fingerprint matching NEITHER
      # recorded side is only movement evidence when the IDENTITY moved too:
      # if the dir still holds exactly the identity the record wrote down, the
      # chain rotated in place, same chain, new bytes. Adopt the new
      # fingerprint into the record (atomic rewrite) and judge that side as
      # UNMOVED, so a pending physical swap survives normal token rotation and
      # still fires at the next process-free window. A fingerprint matching
      # the OTHER side stays movement evidence, and an identity that ALSO
      # differs stays a true MISMATCH, both refuse exactly as before.
      local opfpa="$pfpa" opfpb="$pfpb" fp_healed=0
      if [[ "$fa_now" != "$opfpa" && "$fa_now" != "$opfpb" && "$cur_a" == "$pida" ]]; then
        pfpa="$fa_now"; fp_healed=1
      fi
      if [[ "$fb_now" != "$opfpb" && "$fb_now" != "$opfpa" && "$cur_b" == "$pidb" ]]; then
        pfpb="$fb_now"; fp_healed=1
      fi
      if (( fp_healed )); then
        local ptmp prest
        prest="$(tail -n +2 "$pending" 2>/dev/null || true)"
        ptmp="$(mktemp "$pending.heal.XXXXXX" 2>/dev/null || true)"
        if [[ -n "$ptmp" ]]; then
          {
            printf '%s|%s|%s|%s|%s|%s\n' "$pda" "$pida" "$pdb" "$pidb" "$pfpa" "$pfpb"
            # `if`, not `[[ ]] &&`: with no further pairs the && form leaves
            # the group's exit status at 1 and the mv below never runs
            if [[ -n "$prest" ]]; then printf '%s\n' "$prest"; fi
          } > "$ptmp" && mv "$ptmp" "$pending" || rm -f "$ptmp"
        fi
        printf 'normalize: pending fingerprints refreshed (in-place token rotation), the recorded chains rotated legitimately; the physical swap stays pending.\n'
      fi

      cred_state="MISMATCH"
      if   [[ "$fa_now" == "$pfpa" && "$fb_now" == "$pfpb" ]]; then cred_state="UNMOVED"
      elif [[ "$fa_now" == "$pfpb" && "$fb_now" == "$pfpa" && "$pfpa" != "$pfpb" ]]; then cred_state="SWAPPED"
      fi
      id_state="MISMATCH"
      if   [[ "$cur_a" == "$pida" && "$cur_b" == "$pidb" ]]; then id_state="UNMOVED"
      elif [[ "$cur_a" == "$pidb" && "$cur_b" == "$pida" ]]; then id_state="SWAPPED"
      fi

      if [[ "$cred_state" == "SWAPPED" && "$id_state" == "SWAPPED" ]]; then
        # someone (a completed earlier run, a manual mv) already put the pair right
        printf 'normalize: pending pair %s / %s already fully swapped, clearing the record.\n' \
          "$(tilde "$pda")" "$(tilde "$pdb")"
        clear_pending_head "$pending"
        RECONCILE_SUPPRESS_PENDING=1 cmd_reconcile --apply
        return 0
      elif [[ "$cred_state" == "UNMOVED" && "$id_state" == "UNMOVED" ]]; then
        normalize_swap_pair "$pda" "$pdb" "$pida" "$pidb"
        clear_pending_head "$pending"
        printf 'normalize: swapped. Reconciling the map against the (now truthful) dirs:\n'
        RECONCILE_SUPPRESS_PENDING=1 cmd_reconcile --apply
        return 0
      elif [[ "$cred_state" == "UNMOVED" && "$id_state" == "SWAPPED" ]]; then
        # a validated partial: identities are already right, the credentials
        # provably never moved, complete ONLY the missing half
        printf 'normalize: identities already swapped, credentials provably unmoved, completing the credential half only.\n'
        normalize_swap_pair "$pda" "$pdb" "$pida" "$pidb" .credentials.json
        clear_pending_head "$pending"
        RECONCILE_SUPPRESS_PENDING=1 cmd_reconcile --apply
        return 0
      else
        # every other shape, a fingerprint that matches neither side, a
        # half-swap where the CREDENTIALS moved but the identities did not
        # (re-swapping would invert the landed half: permanent, invisible
        # cross-billing), a vanished file, is beyond safe automation.
        printf 'normalize: REFUSED, the pending pair no longer matches its record (credentials: %s, identities: %s).\n' \
          "$cred_state" "$id_state" >&2
        printf '  %s: holds identity %s (recorded %s), credential fingerprint %s (recorded %s)\n' \
          "$(tilde "$pda")" "${cur_a:-none}" "$pida" "$fa_now" "$pfpa" >&2
        printf '  %s: holds identity %s (recorded %s), credential fingerprint %s (recorded %s)\n' \
          "$(tilde "$pdb")" "${cur_b:-none}" "$pidb" "$fb_now" "$pfpb" >&2
        printf 'Nothing was moved. Manual inspection needed: check the two .credentials.json + .claude.json files above, fix by hand (or re-login one dir), then delete %s.\n' \
          "$(tilde "$pending")" >&2
        pool_notify_once "normalize-mismatch" "Pool normalize needs manual inspection: $(tilde "$pda") / $(tilde "$pdb") no longer match the pending record. See rota keeper-status."
        exit 6
      fi
    fi
  fi

  # ── path 2: label-mismatch detection (a stale map that never reconciled) ───
  local i j a=-1 b=-1
  local NID=()
  for i in "${!DIRS[@]}"; do
    NID[i]="$(config_email "${DIRS[$i]}")"
  done
  # the swap shape: dir A holds B's label and dir B holds A's label
  for i in "${!DIRS[@]}"; do
    [[ -n "${NID[$i]}" && "${NID[$i]}" != "${LABELS[$i]}" ]] || continue
    for j in "${!DIRS[@]}"; do
      (( j == i )) && continue
      if [[ "${NID[$i]}" == "${LABELS[$j]}" && "${NID[$j]:-}" == "${LABELS[$i]}" ]]; then
        a=$i; b=$j; break 2
      fi
    done
  done
  if (( a < 0 )); then
    printf "normalize: no swapped dir pair found (no two dirs hold each other's accounts, no pending record), nothing to do.\n"
    return 0
  fi
  normalize_swap_pair "${DIRS[$a]}" "${DIRS[$b]}" "${NID[$a]}" "${NID[$b]}"
  printf 'normalize: swapped. Reconciling the map against the (now truthful) dirs:\n'
  RECONCILE_SUPPRESS_PENDING=1 cmd_reconcile --apply
}

# ── pool v2 bootstrap: pool-init + adopt-shared (a fresh laptop, 2026-08-12) ─
# A fresh machine has NO pool tooling: a real `claude` on PATH, one shared
# ~/.claude login, no pool dirs. These two verbs stand the pointer-switch
# layout up from that state; both are idempotent and neither ever COPIES a
# credential (adopt-shared MOVES the one shared file, once).
#
# THE ROSTER IS THE ACCOUNTS FILE. There is no built-in list of seats: the
# accounts file ($CFG_DIR/accounts, one "email|dir" per line, in launch
# order) is the only roster, and pool-init builds exactly what it lists.
# Without one there is nothing to build, so pool-init (and roster) print how
# to create the file and exit 2 rather than inventing seats.
# INVARIANT: no spaces (or |) anywhere in the pool root or the dirs under it.
# The accounts file is |-delimited with whitespace-stripping parsers, and the
# ps-output parsers (live_claude_pins, any_live_claude) split env values on
# whitespace, a space in a pool path breaks BOTH. $HOME/.claude-pool on a
# normal macOS user account satisfies this; keep it that way.
POOL_ROOT="${CLAUDE_POOL_DIR:-$HOME/.claude-pool}"
# The link topology (verified read-only on a live pool, 2026-08-12):
# settings.json, commands, skills, plans AND projects are all SYMLINKS into
# ~/.claude, so sessions keep one config + one transcript store across
# accounts; everything else (credentials, .claude.json, caches, history) stays
# per-dir.
POOL_LINKS=(settings.json commands skills plans projects)

# The one message for "there is no accounts file yet", shared by pool-init and
# roster. It names the template that ships with rota and the exact path to put
# it at, so a fresh machine never has to guess the format.
accounts_file_missing_guidance() {
  local example="$ROTA_LIB/../config/accounts.example"
  cat >&2 <<EOF
rota-engine: no accounts file at $(tilde "$ACCOUNTS_FILE"), so there is no roster to build a pool from.
Create it with one "email|config_dir" line per seat you own, in your preferred launch order:

    personal@example.com|$HOME/.claude-pool/personal
    work@example.com|$HOME/.claude-pool/work

A commented template ships with rota as config/accounts.example. Copy it into place and edit the emails:

    mkdir -p $(tilde "$CFG_DIR") && cp $(tilde "$example") $(tilde "$ACCOUNTS_FILE")

then re-run: rota pool-init
EOF
}

cmd_pool_init() {
  [[ $# -eq 0 ]] || die "usage: rota failover pool-init"
  if [[ ! -f "$ACCOUNTS_FILE" ]]; then
    accounts_file_missing_guidance
    exit 2
  fi
  load_accounts
  local made=0 linked=0 seats=0
  mkdir -p "$CFG_DIR" "$POOL_ROOT" "$HOME/.claude"

  local i dir label t src dst
  for i in "${!DIRS[@]}"; do
    dir="${DIRS[$i]}"; label="${LABELS[$i]}"
    # the shared ~/.claude is the pointer slot, not a seat: a row that maps an
    # account there is left exactly alone (nothing to create, nothing to link)
    if [[ "$dir" == "$HOME/.claude" ]] || { [[ -d "$dir" ]] && [[ "$dir" -ef "$HOME/.claude" ]]; }; then
      printf 'note: %s maps to the shared ~/.claude, which is not a pool dir; skipped\n' "$label" >&2
      continue
    fi
    seats=$((seats + 1))
    if [[ ! -d "$dir" ]]; then
      mkdir -p "$dir"
      made=$((made + 1))
      printf 'created %s for %s\n' "$(tilde "$dir")" "$label"
    fi
    for t in "${POOL_LINKS[@]}"; do
      src="$HOME/.claude/$t"; dst="$dir/$t"
      # the link must not dangle: a missing dir target is created, a missing
      # settings.json becomes an empty (valid) JSON object
      if [[ "$t" == "settings.json" ]]; then
        [[ -e "$src" ]] || printf '{}\n' > "$src"
      else
        mkdir -p "$src"
      fi
      if [[ -L "$dst" ]]; then
        # repoint a wrong symlink; a correct one is the idempotent no-op
        [[ "$(readlink "$dst")" == "$src" ]] || { rm -f "$dst"; ln -s "$src" "$dst"; }
      elif [[ -e "$dst" ]]; then
        printf 'note: %s exists and is NOT a symlink, left alone (real per-dir state outranks the shared link)\n' \
          "$(tilde "$dst")" >&2
      else
        ln -s "$src" "$dst"
        linked=$((linked + 1))
      fi
    done
  done

  if (( made + linked == 0 )); then
    printf 'pool-init: already initialized: %d pool dir(s) from %s, links healthy. Nothing changed.\n' \
      "$seats" "$(tilde "$ACCOUNTS_FILE")"
  else
    printf 'pool-init: %d dir(s) created, %d link(s) made for %d seat(s) in %s. No credentials were created or touched.\n' \
      "$made" "$linked" "$seats" "$(tilde "$ACCOUNTS_FILE")"
    printf 'Next: `rota adopt-shared` moves this box'"'"'s shared login into its pool dir; every OTHER seat needs one browser login: rota login <seat>\n'
  fi
  return 0
}

# Any live claude process AT ALL (pinned or not) blocks adopt-shared: an
# unpinned session holds the SHARED chain in memory and would rotate the moved
# credential's twin. Prints "pid[,pid…]" or nothing. Same ps evidence
# (pool_ps) the normalize gate uses, minus the CLAUDE_CONFIG_DIR filter.
any_live_claude() {
  pool_ps | awk '
    NR == 1 && $1 == "PID" { next }
    {
      cmd = $5; sub(".*/", "", cmd)
      if (cmd == "claude" || cmd == "claude.exe") pids = pids (pids ? "," : "") $1
    }
    END { if (pids) print pids }' 2>/dev/null || true
}

cmd_adopt_shared() {
  [[ $# -eq 0 ]] || die "usage: rota failover adopt-shared"
  pool_mutate_acquire || pool_mutate_busy_die "adopt-shared"
  local shared_cred="$HOME/.claude/.credentials.json"

  # 0. zero live claude processes, or the moved file's in-memory twin husks it
  local pids
  pids="$(any_live_claude)"
  if [[ -n "$pids" ]]; then
    printf 'adopt-shared: REFUSED, live claude process(es) running (pids %s). An unpinned session holds the shared chain in memory and would rotate it over the moved file. Quit every claude session, then re-run.\n' \
      "$pids" >&2
    exit 3
  fi

  # 1. whose login is this?
  local claim
  claim="$(json_email "$HOME/.claude.json")"
  [[ -n "$claim" ]] || die "adopt-shared: ~/.claude.json carries no oauthAccount, there is no shared login to adopt. Log each account into its own pool dir instead: CLAUDE_CONFIG_DIR=$(tilde "$POOL_ROOT")/<alias> claude"

  # 2. its pool dir must exist (pool-init creates it)
  local ti=-1 i
  for i in "${!LABELS[@]}"; do
    [[ "${LABELS[$i]}" == "$claim" ]] && { ti="$i"; break; }
  done
  (( ti >= 0 )) || die "adopt-shared: $claim is not in the accounts file, run \`rota pool-init\` first"
  local tdir="${DIRS[$ti]}"
  [[ -d "$tdir" ]] || die "adopt-shared: $claim maps to $(tilde "$tdir") but that dir does not exist, run \`rota pool-init\` first"

  # 3. never create twin chains: a complete credential already in the pool dir
  #    means the shared file is (at best) a second copy of the same account,
  #    exactly the one-account-two-files shape every incident traces back to.
  if cred_is_complete "$tdir/.credentials.json"; then
    printf 'adopt-shared: REFUSED, %s already holds a complete credential for %s. Moving the shared login there would create twin refresh chains (single-use tokens: one husks the other). If the shared file is stale, delete it (rm %s) instead; if the POOL file is stale, re-login that dir first.\n' \
      "$(tilde "$tdir")" "$claim" "$(tilde "$shared_cred")" >&2
    exit 4
  fi

  # 4. macOS can hold the shared login ONLY in the Keychain, with no
  #    .credentials.json on disk, a file we cannot read and must not script
  #    at. A husk on disk is the same answer: nothing movable.
  if [[ ! -f "$shared_cred" ]] || ! cred_is_complete "$shared_cred"; then
    printf 'adopt-shared: the shared login has no movable credential file (%s), on macOS the login can live ONLY in the Keychain, and Keychain reads are operator-only.\n' \
      "$([[ -f "$shared_cred" ]] && echo "the file at $(tilde "$shared_cred") is a husk" || echo "no $(tilde "$shared_cred")")" >&2
    printf 'Do one fresh browser login straight into the pool dir instead:\n' >&2
    printf '    CLAUDE_CONFIG_DIR=%s claude auth login --claudeai\n' "$(tilde "$tdir")" >&2
    exit 5
  fi

  # 5. MOVE, never copy, same filesystem (~/.claude → ~/.claude-pool), so the
  #    mv is a rename and there is no instant with two live copies on disk.
  mv "$shared_cred" "$tdir/.credentials.json" \
    || die "adopt-shared: could not move $(tilde "$shared_cred") into $(tilde "$tdir")"
  chmod 600 "$tdir/.credentials.json" 2>/dev/null || true
  printf 'adopt-shared: moved the shared credential into %s (no copy left behind).\n' "$(tilde "$tdir")"

  # 6. the dir's own .claude.json gets the identity (create it, or preserve
  #    every other key); ~/.claude.json KEEPS its oauthAccount, that is the
  #    claim/pointer the shim resolves.
  local tgt_cfg="$tdir/.claude.json" tmp oa
  oa="$(jq -c '.oauthAccount' "$HOME/.claude.json" 2>/dev/null || true)"
  if [[ -n "$oa" && "$oa" != "null" ]]; then
    tmp="$tgt_cfg.failover-tmp.$$"
    if [[ -f "$tgt_cfg" ]]; then
      jq --argjson oa "$oa" '.oauthAccount = $oa' "$tgt_cfg" > "$tmp" 2>/dev/null \
        && mv "$tmp" "$tgt_cfg" || { rm -f "$tmp"; die "adopt-shared: could not write $(tilde "$tgt_cfg")"; }
    else
      printf '{"oauthAccount":%s}\n' "$oa" > "$tgt_cfg"
    fi
    chmod 600 "$tgt_cfg" 2>/dev/null || true
    printf 'adopt-shared: %s now claims %s; ~/.claude.json keeps the same claim (it is the pointer).\n' \
      "$(tilde "$tgt_cfg")" "$claim"
  fi

  # 7. and the Keychain copies go, so the moved file is the ONLY source
  local kc_state
  kc_state="$(purge_shared_keychain)"
  case "$kc_state" in
    removed) echo "removed stale shared Keychain item(s), the pool file is now the only source" >&2 ;;
    stuck)   echo "WARNING: a shared Keychain item could not be deleted, inspect with: security dump-keychain | grep Claude" >&2 ;;
  esac
  printf 'adopt-shared: done. New `claude` launches pin to %s via the shim; the other roster accounts still need one browser login each.\n' \
    "$(tilde "$tdir")"
  return 0
}

slot_logged_in() {  # slot_logged_in <slot-index>
  local i="${1:--1}"
  [[ "$i" =~ ^[0-9]+$ ]] || return 1
  has_credential "${DIRS[$i]}" && return 0
  [[ -n "$SHARED_EMAIL" ]] && (( i == SHARED_SLOT )) && return 0
  return 1
}

# The email `claude auth status` reports for the SHARED account, i.e. what a plain
# `claude` session displays.
#
# `env -u CLAUDE_CONFIG_DIR` is the whole point and must not be "simplified" back to
# CLAUDE_CONFIG_DIR="$HOME/.claude": the CLI resolves $CLAUDE_CONFIG_DIR/.claude.json,
# so setting it to $HOME/.claude reads the NESTED ~/.claude/.claude.json (stale here,
# and never written by this script) instead of the ~/.claude.json a real session uses.
# That single wrong-file probe is what PR #433 misread as "auth status is untrustworthy"
# see the header block. Unsetting it also drops any CLAUDE_CONFIG_DIR we inherited
# from the surrounding session, which would otherwise aim the probe at a pool dir.
#
# `|| true`: auth status exits non-zero when there is no login, and grep exits 1 when
# the JSON has no email key, under set -e/pipefail either would abort the caller.
shared_email() {
  env -u CLAUDE_CONFIG_DIR claude auth status 2>/dev/null \
    | grep -o '"email": *"[^"]*"' | head -1 | sed 's/.*"email": *"//; s/"$//' || true
}

# ── usage API ────────────────────────────────────────────────────────────────
# One fetch per token per run, ever: the API rate-limits PER TOKEN at roughly
# 1 call/min, and the account holding the shared ~/.claude is the one live sessions
# poll, so it is the most likely to answer 429.
#
# Answers through GLOBALS (USAGE_JSON, USAGE_HTTP) rather than stdout on purpose: a
# `json="$(usage_fetch …)"` capture runs the function in a SUBSHELL, so the status
# code it recorded would die with that subshell and every caller would see an empty
# HTTP code, which silently disables the whole 429 branch.
USAGE_HTTP=""
USAGE_JSON=""
USAGE_CURL_TIMEOUT=10
# ⚠️ THE USER-AGENT CHANGES THE ANSWER. The keeper has sent `claude-code/2.x`
# since 2026-08-12 and calls it mandatory; this probe never did, and the two
# disagreed about the same token. Measured on the pool host 2026-08-30, 150s of
# quiet before each call, no live session on the seat, one EXPIRED access token:
#   no User-Agent (curl's default)   → HTTP 429 "Rate limited. Please try again later."
#   User-Agent: claude-code/2.x      → HTTP 401 "OAuth access token has expired."
# So the 429 this probe kept reporting for four seats was the vendor's answer to
# an expired token under the default UA, not rate limiting, and the row's "retry
# in ~1 min" advice was built on it. Same header as the keeper, one probe shape.
USAGE_UA="${CLAUDE_FAILOVER_USAGE_UA:-claude-code/2.x}"
usage_fetch() {
  local token="$1" resp
  USAGE_HTTP=""; USAGE_JSON=""
  [[ -n "$token" ]] || { USAGE_HTTP="no-token"; return 0; }
  resp="$(curl -s --max-time "$USAGE_CURL_TIMEOUT" -w $'\n%{http_code}' \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "User-Agent: $USAGE_UA" \
    "$USAGE_API" 2>/dev/null || true)"
  USAGE_HTTP="${resp##*$'\n'}"
  [[ "$USAGE_HTTP" == "200" ]] || return 0
  USAGE_JSON="${resp%$'\n'*}"
}

usage_field() { printf '%s' "$1" | jq -r "$2 // empty" 2>/dev/null || true; }

# ── the BINDING weekly limit ─────────────────────────────────────────────────
# `seven_day.utilization` is only ONE of the weekly limits an account has. The full
# response also carries a `limits` array, and a SCOPED (per-model) weekly entry can sit
# far above the all-model one:
#
#   "limits":[{"kind":"session",      "group":"session","percent":34,...,"scope":null},
#             {"kind":"weekly_all",   "group":"weekly", "percent":21,...,"scope":null},
#             {"kind":"weekly_scoped","group":"weekly", "percent":2, ...,
#              "scope":{"model":{"id":null,"display_name":"Fable"}}}]
#
# Whichever weekly entry is HIGHEST is the one that will actually wall you. Reading only
# seven_day (== weekly_all) means a scoped cap at 95% is invisible and the dashboard
# reports comfortable headroom right up to the moment the account stops answering.
#
# So the weekly figure is max(percent) over group=="weekly", carrying THAT entry's own
# resets_at, kind and scope. Deliberately generic: `seven_day_opus`/`seven_day_sonnet`
# are null on every account here and ccstatusline already shows them, whereas `limits`
# is the mechanism that describes whatever caps an account actually has.
#
# FALLS BACK SAFELY: no `limits` key, an empty array, a non-array, junk entries, no
# weekly group, or unparseable JSON all leave WB_PCT empty, and the caller then uses
# seven_day exactly as before, an older or differently-shaped response must not break
# the tool.
#
# Fields come back \x1f-joined, NOT tab-joined: tab is IFS *whitespace*, so bash would
# collapse a run of tabs and silently drop the empty fields (a scoped entry with a null
# resets_at, or an unscoped one, produces exactly those), the same trap cache_get
# documents. \x1f delimits exactly one field each and empties round-trip.
#
# WB_ALL_RESET is separate on purpose: the identity fingerprint compares weekly reset
# MINUTES across accounts, which is only meaningful between the same kind of window, so
# it keeps using seven_day/weekly_all rather than whatever kind happens to bind.
WB_PCT=""; WB_RESET=""; WB_KIND=""; WB_SCOPE=""; WB_ALL_RESET=""
weekly_binding() {  # weekly_binding <usage-json>
  local json="${1:-}" row
  WB_PCT=""; WB_RESET=""; WB_KIND=""; WB_SCOPE=""; WB_ALL_RESET=""
  [[ -n "$json" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  # `try … catch null` guards a scope that is present but not the expected object shape
  # (a bare string, say), so a surprising payload degrades to "unscoped" instead of
  # aborting the whole run. A null scope, or a scope whose display_name is null, yields
  # "", never the string "null".
  row="$(printf '%s' "$json" | jq -r '
    ([ (.limits // []) | (if type=="array" then .[] else empty end)
       | select(type=="object" and .group=="weekly" and (.percent|type)=="number") ]) as $w
    | ($w | map(select(.kind=="weekly_all")) | .[0]) as $all
    | ($w | sort_by(.percent, (if .kind=="weekly_all" then 1 else 0 end)) | last) as $b
    | [ (if $b == null then "" else ($b.percent|tostring) end),
        (if $b == null then "" else ($b.resets_at // "") end),
        (if $b == null then "" else ($b.kind // "") end),
        (if $b == null then "" else
           (((try $b.scope.model.display_name catch null)
             // (try $b.scope.name catch null)) // "") end),
        (($all.resets_at) // "") ]
    | join("\u001f")' 2>/dev/null || true)"
  [[ -n "$row" ]] || return 0
  IFS=$'\x1f' read -r WB_PCT WB_RESET WB_KIND WB_SCOPE WB_ALL_RESET <<<"$row"
}

# "  (binding: Opus)" for a SCOPED binding limit, "" otherwise, so a weekly number that
# is really a per-model cap can never be mistaken for the all-model one. Silent for
# weekly_all and for the seven_day fallback, where there is nothing to disambiguate.
scope_note() {  # scope_note <scope-display-name>
  [[ -n "${1:-}" ]] || return 0
  printf '  (binding: %s)' "$1"
}

# Remaining %, the number that decides anything: "8% left" is what you act on.
#
# But it must never be printed ALONE, and never FIRST. Claude Code's own statusline
# reports the OPPOSITE polarity, utilization, "Weekly: 13%" meaning 13% USED, and on
# 2026-07-30 a `usage` row reading "87% left" next to a statusline reading "13%" was
# taken as the two surfaces naming DIFFERENT ACCOUNTS, when they were the same account
# described from opposite ends. Printing both fixed the arithmetic but not the reading:
# with "87% left · 13% used" the eye still lands on 87 where the statusline shows 13,
# and the mismatch kept reading as a wrong account. So both are printed and USED LEADS,
# in the statusline's own position: "13% used · 87% left". Every rendered window row,
# every exclusion reason and every recommendation sentence uses that order.
remaining() {
  local u="${1:-}" i r
  [[ -n "$u" ]] || return 0
  i="${u%.*}"; [[ -n "$i" ]] || i=0
  [[ "$i" =~ ^[0-9]+$ ]] || return 0
  r=$((100 - i)); (( r < 0 )) && r=0
  printf '%s' "$r"
}

# Used %, the raw API utilization, normalised to the same integer domain as
# remaining() so the pair always sums to 100 and can be matched against the
# statusline at a glance.
used() {
  local u="${1:-}" i
  [[ -n "$u" ]] || return 0
  i="${u%.*}"; [[ -n "$i" ]] || i=0
  [[ "$i" =~ ^[0-9]+$ ]] || return 0
  (( i > 100 )) && i=100
  printf '%s' "$i"
}

# THREE window states, which must never be conflated (fixed 2026-07-30):
#
#   FRESH       utilization parses, but there is no resets_at. The window has not
#               STARTED, so 100% is left and nothing is expiring. The API answers
#               literally this for an account whose weekly window has reset and
#               that has spent nothing since:
#                 {"seven_day":{"utilization":0.0,"resets_at":null,...},...}
#               That is the healthiest possible state and the best thing to switch
#               to, yet it used to render as "resets no active window" and then be
#               EXCLUDED as "incomplete usage data", so the account with the most
#               headroom was the one account this tool refused to recommend
#               (observed on a live seat).
#   INCOMPLETE  utilization itself is absent or unparseable (or the fetch failed).
#               Genuinely unknown, still excluded, still says so.
#   NORMAL      utilization + resets_at. Unchanged.
#
# An EXPIRED cached window is none of the three: its number was measured inside a
# window that no longer exists, so it is not fresh however good it looks.
window_fresh() {  # window_fresh <util> <reset-iso> <expired 0|1>
  (( ${3:-0} == 0 )) || return 1
  [[ -z "${2:-}" ]] || return 1
  [[ -n "$(remaining "${1:-}")" ]]
}

# ── time formatting ──────────────────────────────────────────────────────────
# ISO-8601 → epoch seconds. The usage API answers e.g.
# 2026-08-03T15:59:59.731851+00:00, so strip the fraction and the (always UTC)
# zone before handing it to date(1). BSD date first (macOS), GNU date as fallback.
iso_epoch() {
  local iso="${1:-}" base norm
  [[ -n "$iso" ]] || return 0
  base="${iso%%.*}"
  norm="${base%%+*}"; norm="${norm%Z}"
  date -j -u -f '%Y-%m-%dT%H:%M:%S' "$norm" '+%s' 2>/dev/null && return 0
  date -u -d "$iso" '+%s' 2>/dev/null && return 0
  return 0
}

epoch_fmt() { date -r "$1" "$2" 2>/dev/null || date -d "@$1" "$2" 2>/dev/null || printf '?'; }

# epoch → the UTC ISO instant every machine surface in this tool speaks (the same
# shape cache_flush's fetched_at and json_usage's generated_at already use). NOT
# epoch_fmt, which renders in LOCAL time: a measurement stamp that silently
# changes meaning with $TZ is the kind of number two boxes cannot compare.
epoch_iso() {  # epoch_iso <epoch-seconds>
  [[ "${1:-}" =~ ^[0-9]+$ ]] || return 0
  date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true
}

# HOW OLD IS THIS NUMBER, in the one form you can read without stopping: a single
# coarse unit, "4m" / "3h" / "2d". Deliberately not human_delta's two-unit "2d3h"
# (that answers "how long have I got", a countdown, where the second unit earns
# its place) and deliberately not a timestamp: the age rides in a NOTES cell next
# to the number it qualifies, where anything longer stops being glanceable.
#
# 2026-08-27, the defect that made this necessary: a seat whose stored token has
# been dead for days (nothing runs a session on it, so the keeper cannot rotate
# it either) rendered a confident `27%` weekly behind a bare `[quota cached]`.
# A 2.5-day-old number shown like a live one is worse than a blank, because a
# blank sends you to look and a confident number does not.
# Below this the source marker alone is enough: a number measured in the last two
# minutes is, for every purpose this table serves, now. The threshold is applied
# INSIDE age_short, not at each call site: a guard a caller has to remember is a
# guard some caller will forget, and forgetting it here prints "0m old" next to a
# number measured this second.
# ⚠️ rota-billing.sh has the twin of this pair (its table is rendered in Python).
# If this 120 moves, move that one: two surfaces disagreeing about when a number
# stops being current is worse than either threshold on its own.
AGE_VISIBLE_SECS=120
age_short() {  # age_short <measured-at-epoch> → "" when it is young enough to be "now"
  local te="${1:-}" now d
  [[ "$te" =~ ^[0-9]+$ ]] || return 0
  now="$(date '+%s')"
  d=$((now - te)); (( d < 0 )) && d=0
  (( d > AGE_VISIBLE_SECS )) || return 0
  if   (( d >= 86400 )); then printf '%dd' $((d / 86400))
  elif (( d >= 3600 ));  then printf '%dh' $((d / 3600))
  else                        printf '%dm' $((d / 60)); fi
}

# Whole seconds from now until an ISO instant, the machine-readable twin of
# human_delta(), so a --json consumer renders its own countdown instead of parsing
# "in 4h31m" back into arithmetic. Prints NOTHING (→ null) when there is no instant
# or date(1) cannot decode it: never a 0 that would read as "resetting right now".
# A stamp already in the past clamps to 0, the only stamps that can be in the past
# are EXPIRED cached windows, which already null their percentages.
iso_in_seconds() {
  local iso="${1:-}" secs now d
  [[ -n "$iso" ]] || return 0
  secs="$(iso_epoch "$iso")"
  [[ "$secs" =~ ^-?[0-9]+$ ]] || return 0
  now="$(date '+%s')"
  d=$((secs - now)); (( d < 0 )) && d=0
  printf '%s' "$d"
}

human_delta() {
  local s="${1:-0}" d h m
  (( s < 0 )) && { printf 'already reset'; return 0; }
  d=$((s / 86400)); h=$(((s % 86400) / 3600)); m=$(((s % 3600) / 60))
  if (( d > 0 )); then printf 'in %dd%dh' "$d" "$h"
  elif (( h > 0 )); then printf 'in %dh%02dm' "$h" "$m"
  else printf 'in %dm' "$m"; fi
}

# "19:00 today (in 4h07m)", local time + relative, because a raw UTC ISO stamp
# with microseconds is not something you can act on without doing arithmetic first.
fmt_reset() {
  local iso="${1:-}" secs now day today tomorrow when
  [[ -n "$iso" ]] || { printf 'no active window'; return 0; }
  secs="$(iso_epoch "$iso")"
  [[ -n "$secs" ]] || { printf '%s' "$iso"; return 0; }
  now="$(date '+%s')"
  day="$(epoch_fmt "$secs" '+%Y-%m-%d')"
  today="$(date '+%Y-%m-%d')"
  tomorrow="$(epoch_fmt "$((now + 86400))" '+%Y-%m-%d')"
  if [[ "$day" == "$today" ]]; then when="$(epoch_fmt "$secs" '+%H:%M') today"
  elif [[ "$day" == "$tomorrow" ]]; then when="$(epoch_fmt "$secs" '+%H:%M') tomorrow"
  else when="$(epoch_fmt "$secs" '+%H:%M %a %-d %b')"; fi
  printf '%s (%s)' "$when" "$(human_delta $((secs - now)))"
}

# The reset clause of any sentence a human reads: a real instant when there is one,
# an honest phrase when the window has not started yet. Every such sentence goes
# through this, so a FRESH account can never be handed an invented reset time.
reset_phrase() {  # reset_phrase <reset-iso>
  if [[ -z "${1:-}" ]]; then printf 'no active window yet (starts on first use)'
  else printf 'resets %s' "$(fmt_reset "$1")"; fi
}

# "today 18:30" / "tomorrow 16:00" / "Mon 10 Aug 18:00", the DAY first, so a
# column of them scans top-to-bottom, and with no relative clause: this is the
# UNAVAILABLE column, where the only question is when the account comes back.
# (The ACTIVE block uses human_delta instead, "resets in 6d11h", because there
# the question is how long the headroom you are spending has left.)
when_short() {  # when_short <reset-iso>
  local iso="${1:-}" secs now day today tomorrow
  [[ -n "$iso" ]] || return 0
  secs="$(iso_epoch "$iso")"
  [[ -n "$secs" ]] || return 0
  now="$(date '+%s')"
  day="$(epoch_fmt "$secs" '+%Y-%m-%d')"
  today="$(date '+%Y-%m-%d')"
  tomorrow="$(epoch_fmt "$((now + 86400))" '+%Y-%m-%d')"
  if   [[ "$day" == "$today" ]];    then printf 'today %s' "$(epoch_fmt "$secs" '+%H:%M')"
  elif [[ "$day" == "$tomorrow" ]]; then printf 'tomorrow %s' "$(epoch_fmt "$secs" '+%H:%M')"
  else printf '%s %s' "$(epoch_fmt "$secs" '+%a %-d %b')" "$(epoch_fmt "$secs" '+%H:%M')"; fi
}

# ── usage cache ──────────────────────────────────────────────────────────────
# Last-good utilization numbers per account (never tokens), so a rate-limited or
# stale row can still show something. A cached row whose weekly window has ALREADY
# RESET is not merely old, it is WRONG: the number was measured in a window that no
# longer exists. The first run of this dashboard cheerfully printed "100% / resets
# 2026-07-27" for an account that had since reset to 30%, cached and live rows
# looked identical apart from a parenthetical. Such a window now prints "expired".
#
# cache_put QUEUES (no disk write); cache_flush writes every queued account in
# ONE read-modify-write. This is best-effort cache data that self-heals on the
# next live fetch, so it is not worth a lock: two concurrent `rota usage` runs
# can still race on the final mv and one's update to a different key can be
# lost, but collapsing a run's N per-account writes into a single flush shrinks
# that window from "per account" to "per run" without adding lock/stale-lock
# complexity for data that was never authoritative.
CACHE_PEND_EMAIL=(); CACHE_PEND_WKU=(); CACHE_PEND_WKR=(); CACHE_PEND_SEU=(); CACHE_PEND_SER=()
cache_put() {  # cache_put <email> <wk_u> <wk_r> <se_u> <se_r>, queues; see cache_flush
  [[ -n "${1:-}" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  CACHE_PEND_EMAIL+=("$1"); CACHE_PEND_WKU+=("${2:-}"); CACHE_PEND_WKR+=("${3:-}")
  CACHE_PEND_SEU+=("${4:-}"); CACHE_PEND_SER+=("${5:-}")
}

# ⚠️ A CACHE THAT STOPS UPDATING MUST NOT DO IT QUIETLY. The merge is one jq
# invocation, and if a jq build ever rejects it EVERY field freezes, not just
# the new one: the numbers would keep rendering, keep looking current, and keep
# being last week's, which is the exact shape of confidently-wrong this whole
# file argues against. So a failed merge says so on stderr, ONCE per run (the
# same failure repeats per account and a wall of identical lines is its own way
# of being ignored), and names the file so the next step is obvious.
CACHE_MERGE_WARNED=0
cache_merge_warn() {
  (( CACHE_MERGE_WARNED )) && return 0
  CACHE_MERGE_WARNED=1
  printf 'rota: could NOT update the usage cache at %s (jq rejected the row merge). The numbers already on disk are being kept as they are; nothing new is being written, so every cached row will go on aging.\n' \
    "$USAGE_CACHE" >&2
  return 0
}

cache_flush() {
  (( ${#CACHE_PEND_EMAIL[@]} )) || return 0
  command -v jq >/dev/null 2>&1 || return 0
  mkdir -p "$CFG_DIR"
  local data idx n=${#CACHE_PEND_EMAIL[@]} ts te fa
  ts="$(date '+%b %d %H:%M')"; te="$(date '+%s')"
  # fetched_at (pool v2): the machine-readable fetch instant every cache row
  # now carries, so consumers (the dashboard's `stale Xh` rendering, the
  # keeper) judge freshness without parsing the human `ts` stamp back apart.
  fa="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  data="$(cat "$USAGE_CACHE" 2>/dev/null || echo '{}')"
  # a corrupt cache (truncated write, disk hiccup) must SELF-HEAL: without
  # this every per-row jq below fails silently and the junk lives forever
  jq -e . <<<"$data" >/dev/null 2>&1 || data='{}'
  # The merge itself is rota_cache_merge_row (rota-ranking.sh), SHARED with the
  # keeper's per-tick writer: see there for what wk_r_seen is and why an empty
  # reading may not overwrite it. Two copies of this jq is how the two writers
  # would come to disagree, and the keeper writes every minute.
  local merged
  for (( idx = 0; idx < n; idx++ )); do
    if merged="$(rota_cache_merge_row "$data" "${CACHE_PEND_EMAIL[$idx]}" \
                   "${CACHE_PEND_WKU[$idx]}" "${CACHE_PEND_WKR[$idx]}" \
                   "${CACHE_PEND_SEU[$idx]}" "${CACHE_PEND_SER[$idx]}" \
                   "$ts" "$te" "$fa")"; then
      data="$merged"
    else
      cache_merge_warn
    fi
  done
  printf '%s' "$data" > "$USAGE_CACHE.tmp.$$" 2>/dev/null \
    && mv "$USAGE_CACHE.tmp.$$" "$USAGE_CACHE" || true
  CACHE_PEND_EMAIL=(); CACHE_PEND_WKU=(); CACHE_PEND_WKR=(); CACHE_PEND_SEU=(); CACHE_PEND_SER=()
}

C_WKU=""; C_WKR=""; C_SEU=""; C_SER=""; C_TS=""; C_TE=""; C_WKR_SEEN=""
cache_get() {  # cache_get <email> → C_* globals
  C_WKU=""; C_WKR=""; C_SEU=""; C_SER=""; C_TS=""; C_TE=""; C_WKR_SEEN=""
  [[ -n "${1:-}" && -f "$USAGE_CACHE" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local row
  # \x1f (unit separator), NOT tab. Tab is IFS *whitespace*, so bash collapses a run
  # of tabs into one delimiter and silently DROPS empty fields, every field after an
  # empty one shifts left. That never bit while resets_at was always populated, but a
  # FRESH window caches an empty wk_r/se_r, and the shifted read then handed
  # window_expired the utilization ("0.0") as if it were a timestamp, so a cached fresh
  # row rendered "expired (window reset since)" instead of 100% left. \x1f is not IFS
  # whitespace, so each separator delimits exactly one field and empties round-trip.
  row="$(jq -r --arg e "$1" '(.[$e] // {}) | [.wk_u,.wk_r,.se_u,.se_r,.ts,.ts_epoch,.wk_r_seen] | map(. // "") | join("\u001f")' \
        "$USAGE_CACHE" 2>/dev/null || true)"
  IFS=$'\x1f' read -r C_WKU C_WKR C_SEU C_SER C_TS C_TE C_WKR_SEEN <<<"$row"
}

# ── the weekly reset a seat WILL see, when the API refuses to name it ─────────
#
# ⚠️ A NULL resets_at IS NOT "UNKNOWN", IT IS "NOT REPORTED WHILE UNUSED". The
# usage API answers {"utilization":0.0,"resets_at":null} for a weekly window that
# has rolled and has not been spent in since (window_fresh's FRESH state), while
# the reset instant itself sits on a FIXED 7-day cadence per seat, verified over
# three weeks on this pool. So the healthiest seat there is, the one carrying a
# whole untouched week, was the one seat every surface described as having no
# reset at all: it rendered "weekly reset unknown" and sorted LAST among usable
# seats, and on 2026-09-04 that had `cl` and `cdt accounts` naming two DIFFERENT
# seats in the same minute (measured).
#
# The cadence is known, so the instant is computable: take the last non-empty
# reset ever stored for this email (cache_flush's wk_r_seen) and roll it forward
# in whole weeks until it lands after now. It stays a PROJECTION and never
# becomes a measurement: it lives in its own U_WKP/U_WKPF pair, publishes under
# its own `resets_at_projected` key, and renders with a leading `~` everywhere,
# so nothing can read it as something the vendor said.
#
# The arithmetic itself is rota_roll_forward_weekly (rota-ranking.sh), SHARED
# with the keeper's unattended picker for the same reason rota_seat_deadline is
# shared: two copies of "when does this untouched seat lose its week" is two
# answers to the question that decides which seat gets used.
#
# SILENT (both values empty) wherever a projection would be a claim rather than
# an inference: a real reset exists, the window is an EXPIRED cached one (its
# number describes a window that no longer exists, so there is nothing to
# project FROM), the utilization does not parse (INCOMPLETE, genuinely unknown),
# or this box has never seen a reset for that email at all.
U_WKP=(); U_WKPF=()
project_weekly() {  # project_weekly <slot-index> → fills U_WKP/U_WKPF for that slot
  local i="${1:-}" seen proj
  [[ "$i" =~ ^[0-9]+$ ]] || return 0
  U_WKP[i]=""; U_WKPF[i]=""
  [[ -z "${U_WKR[$i]:-}" ]] || return 0
  # ⚠️ DEFENSIVE, AND UNREACHABLE BY CONSTRUCTION TODAY: U_WKX==1 only ever comes
  # from window_expired on the very stamp that would then be in U_WKR, so the
  # guard above already caught it. It stays because the day some path sets an
  # expired flag without a stamp, projecting there would put a confident deadline
  # on a row whose whole point is "unmeasured, may be full". Exercised directly
  # in tests/engine.test.sh (the projection unit case), not through a fixture.
  (( ${U_WKX[$i]:-0} == 0 )) || return 0
  [[ -n "$(remaining "${U_WKU[$i]:-}")" ]] || return 0
  [[ -n "${U_EMAIL[$i]:-}" ]] || return 0
  cache_get "${U_EMAIL[$i]}"
  seen="$C_WKR_SEEN"
  # THE BACKFILL, READ SIDE. A row written before wk_r_seen existed keeps the
  # last instant in its own wk_r, and cache_flush can only seed the new field on
  # the NEXT write. Without this the first run after an upgrade would still say
  # "unknown" for every seat, which is the exact state this exists to end.
  [[ -n "$seen" ]] || seen="$C_WKR"
  [[ -n "$seen" ]] || return 0
  proj="$(rota_roll_forward_weekly "$seen")"
  [[ -n "$proj" ]] || return 0
  U_WKP[i]="$proj"
  U_WKPF[i]="$seen"
}

# Is this reset instant in the past? Both sides are ISO seconds, so a lexical
# compare is a date compare.
window_expired() {
  local iso="${1:-}" now
  [[ -n "$iso" ]] || return 1          # no stamp → can't prove it expired
  now="$(date -u '+%Y-%m-%dT%H:%M:%S')"
  [[ "${iso:0:19}" < "$now" ]]
}

# Age of a cached row, from its epoch stamp when present (older cache files carry
# only the human stamp, which is still printed on its own).
cache_age() {
  local te="${1:-}" now d
  [[ "$te" =~ ^[0-9]+$ ]] || return 0
  now="$(date '+%s')"
  (( now > te )) || return 0
  d="$(human_delta $((now - te)))"
  printf ' (%s old)' "${d#in }"
}

# ── peer usage: ask the box that legitimately holds the credential ───────────
# THE PROBLEM, measured on the laptop 2026-08-27: four of five seats rendered `-`
# in every quota column and `[quota none]` in NOTES, because this box holds one
# credential. No stored credential → no token → no live fetch → no cache row →
# nothing to print. The code was right about the input it had; the input was the
# problem.
#
# THE OPTION THAT IS REJECTED, and must stay rejected: copying the credentials
# here. An OAuth refresh token is SINGLE-USE, so two boxes holding one account's
# credential means whichever rotates first invalidates the other, the loser 401s,
# and the CLI hollows its file into a husk. That is the 2026-08-07 incident, and
# cred-guard is still warning about it on this very box. A DISPLAY problem must
# never be paid for with a second copy of a credential.
#
# SO: read the NUMBERS from the box that holds the credential. Nothing moves. The
# call is read-only, the payload is percentages and reset instants (usage numbers
# are not secret; tokens are, and none is ever transmitted), and every failure
# mode degrades to exactly the table this box printed before.
#
# WHAT IS ASKED FOR, and why it is `--no-refresh`. Measured durban→ballito:
# handshake alone 2.16s, `rota accounts --json` 4.12s, the same with
# --no-refresh 2.46s. The peer runs the keeper on a 600s interval and its step 3
# fetches usage per account per tick, so its cache IS the freshest thing
# available: forcing a refresh buys ~0s of freshness for ~1.7s of latency. The
# honesty that costs is bought back by quota_measured_at, which travels with
# every row, so a peer number that is two days old SAYS it is two days old.
#
# `rota usage --json --no-refresh` is the fallback in the same ssh (one
# handshake, not two): `rota accounts` needs a billing.json on the peer, and a
# peer without one would otherwise silently contribute nothing.
#
# ROTA_PEERS= on the remote leg, and --local, are the loop guards: a peer that
# has peers of its own must not go on to ssh a third box (or back here) inside
# our timeout. --no-refresh alone already forces NET=0 there, which skips the
# peer step anyway; the env var makes that structural rather than incidental.
PEER_HOST=""            # the peer that answered, "" when none was consulted/usable
PEER_GENERATED=""       # that payload's generated_at, for --json provenance
peer_hosts() {
  local raw="" line
  if [[ -n "${ROTA_PEERS+set}" ]]; then
    raw="$ROTA_PEERS"
  elif [[ -f "$PEERS_FILE" ]]; then
    raw="$(sed 's/#.*//' "$PEERS_FILE" 2>/dev/null || true)"
  fi
  raw="${raw//,/ }"
  # NEVER ssh to ourselves: a peers file copied verbatim onto every box would
  # otherwise make each one wait out a round trip to its own sshd for numbers it
  # already has. FOUR spellings, because which one is right depends on the box:
  # `hostname -s` is short, bare `hostname` and $HOSTNAME can carry the domain,
  # and scutil is macOS-only (and is the name Cédric's fleet actually uses).
  #
  # ⚠️ Compared on the FIRST LABEL as well as verbatim. Truncating only the SELF
  # side is what broke it: with HOSTNAME=durban.local and `durban.local` in the
  # peers file, `durban` matched nothing and the box dialled its own sshd, which
  # is precisely the case the $HOSTNAME spelling exists to catch. The cost of
  # comparing first labels is that two genuinely different boxes sharing one
  # (`mac.local` here, `mac.elsewhere.net` there) would be skipped; on a fleet
  # whose names are `ballito` and `durban` that trade is free, and a wrongly
  # skipped peer degrades to today's table rather than to a wrong one.
  local self_names=() entries=() s short skip
  self_names+=("$(hostname -s 2>/dev/null || true)")
  self_names+=("$(hostname 2>/dev/null || true)")
  self_names+=("$(scutil --get LocalHostName 2>/dev/null || true)")
  self_names+=("${HOSTNAME:-}")
  # WORD splitting is wanted here; GLOB expansion is not. Unquoted `for line in
  # $raw` let a peers line containing `*` expand against the current directory,
  # turning one hostname into a list of filenames. `set -f` for exactly the one
  # expansion, then straight back off.
  set -f
  # shellcheck disable=SC2206  # the split is the point; `set -f` covers the rest
  entries=( $raw )
  set +f
  for line in ${entries+"${entries[@]}"}; do
    [[ -n "$line" ]] || continue
    short="${line%%.*}"; skip=0
    for s in "${self_names[@]}"; do
      [[ -n "$s" ]] || continue
      if [[ "$line" == "$s" || "$short" == "${s%%.*}" ]]; then skip=1; break; fi
    done
    (( skip )) && continue
    printf '%s\n' "$line"
  done
}

# One ssh, hard-bounded. There is no portable `timeout` on macOS, so the bound is
# enforced here: background the call, watch it, and kill it at <budget> seconds.
# ConnectTimeout only covers the connect, and the whole point of this bound is
# that a peer which accepts the connection and then hangs must not hang US.
#
# The budget is passed IN rather than read from PEER_TIMEOUT, because the bound
# the spec asks for is on the whole peer STEP, not on each dial: with three
# hanging peers a per-dial bound spent 3 × PEER_TIMEOUT. peer_fill hands each
# dial whatever is left of the step's deadline. With one peer the two are the
# same number, so the single-peer path is byte-for-byte what it always was.
peer_ssh() {  # peer_ssh <host> <out-file> <budget-secs>   → 0 when it produced something
  local host="$1" out="$2" budget="${3:-$PEER_TIMEOUT}" pid ticks=0 max
  (( budget > 0 )) || return 1
  max=$(( budget * 5 ))          # the watch loop ticks every 0.2s
  local remote='PATH="$HOME/.local/bin:$PATH"; export PATH; '
  remote+='ROTA_PEERS= rota accounts --json --no-refresh --local 2>/dev/null '
  remote+='|| ROTA_PEERS= rota usage --json --no-refresh 2>/dev/null'
  : > "$out" 2>/dev/null || return 1
  # `--` ends the options: a peers line starting with `-` is a hostname we cannot
  # reach, never an ssh flag we did not mean to pass.
  ssh -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=accept-new \
      -o LogLevel=ERROR -- "$host" "$remote" > "$out" 2>/dev/null &
  pid=$!
  while (( ticks < max )); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
    ticks=$((ticks + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    # No graceful path is implied here: TERM immediately followed by KILL IS a
    # kill, and it kills the LOCAL ssh only. The `rota accounts` it started keeps
    # running to completion on the peer, which is fine and worth stating plainly:
    # that command is a read-only measurement, and its own --no-refresh means it
    # does not even reach the network. What we are buying is our own deadline.
    kill -TERM "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    peer_note "$host: no answer within ${budget}s, ignoring it"
    return 1
  fi
  wait "$pid" 2>/dev/null || true
  [[ -s "$out" ]] || { peer_note "$host: answered with nothing, ignoring it"; return 1; }
  return 0
}

# One explanatory line, --verbose only. A peer problem is never worth an error the
# operator has to read: the whole feature is a bonus on top of a table that was
# already correct without it.
peer_note() { (( VERBOSE )) && printf '  peer %s\n' "$1" >&2; return 0; }

# Ctrl-C between the ssh and the mv strands a `.peer.<pid>.json` or a
# `peer-usage-cache.json.tmp.<pid>`. Both are tiny and bounded, but nothing else
# sweeps them, so the step tidies anything an hour old on its way in. Deliberately
# NOT an EXIT trap: this script installs none at all, and claiming the one global
# trap for two stray temp files is a heavier commitment than the litter is worth.
peer_tmp_sweep() {
  find "$CFG_DIR" -maxdepth 1 \
    \( -name '.peer.*.json' -o -name 'peer-usage-cache.json.tmp.*' \) \
    -mmin +60 -delete 2>/dev/null || true
  return 0
}

# ── the peer cache, in BOTH polarities ───────────────────────────────────────
# SUCCESS, 90s (R3): running `rota accounts` twice in a row is what a human does,
# and it must pay the round trip once.
#
# FAILURE, 300s, and this is the one that decides whether the feature is livable.
# Caching only successes meant an unreachable peer was re-dialled on EVERY
# invocation, so for as long as ballito was asleep, every `cdt accounts` on the
# laptop stalled for the full 10s bound. That is a worse daily experience than
# the blank table this feature exists to fix, and the kind of papercut that makes
# a command stop being reached for.
#
# WHY 300s AND NOT 90s, AND NOT AN HOUR. The two costs pull opposite ways: too
# short and a sleeping Mac (which stays asleep for hours) charges the stall over
# and over; too long and a peer that has come BACK keeps being ignored while the
# table it could fill sits there blank. 300s caps a dead peer at one 10s stall
# per five minutes (~3% of the time, even running this constantly) while a woken
# box is picked up within a coffee break. An hour would mean a laptop that woke
# at 09:05 still showing blanks at 09:50, which is the same "this table is lying
# about my seats" complaint we started from. `rm $CFG_DIR/peer-usage-cache.json`
# forces an immediate retry for anyone who does not want to wait.
#
# Atomic write, same tmp.$$ + mv idiom as cache_put, for the same reason: a
# half-written cache must never be readable.
#
# THREE ANSWERS, so the exit code carries what stdout cannot:
#   0  a fresh payload, printed
#   2  this peer failed recently, do NOT dial it again yet
#   1  nothing known, go and dial
peer_cache_get() {  # peer_cache_get <host> → payload on stdout; see the exit codes above
  local host="$1" row age now failed
  [[ -f "$PEER_CACHE" ]] || return 1
  row="$(jq -c --arg h "$host" '.[$h] // empty' "$PEER_CACHE" 2>/dev/null || true)"
  [[ -n "$row" ]] || return 1
  age="$(jq -r '.at // empty' <<<"$row" 2>/dev/null || true)"
  [[ "$age" =~ ^[0-9]+$ ]] || return 1
  now="$(date '+%s')"
  failed="$(jq -r 'if .failed then "1" else "" end' <<<"$row" 2>/dev/null || true)"
  # STRICTLY less-than, on both, so that a TTL of 0 means what "0 seconds of
  # reuse" plainly says: never reuse, always dial. With <= a same-second re-run
  # still matched at age 0, so `ROTA_PEER_TTL=0` silently did nothing. The extra
  # second it costs a real 90s/300s window is not worth a knob that lies.
  if [[ "$failed" == "1" ]]; then
    (( now - age < PEER_FAIL_TTL )) && return 2
    return 1                       # the cooling-off window is over, try again
  fi
  (( now - age < PEER_TTL )) || return 1
  jq -c '.payload // empty' <<<"$row" 2>/dev/null || true
  return 0
}

# One writer for both polarities: a success record REPLACES a failure record and
# vice versa, so a peer that comes back is never held down by its own history.
peer_cache_write() {  # peer_cache_write <host> <payload-json|"">
  local host="$1" payload="${2:-}" data entry
  mkdir -p "$CFG_DIR" 2>/dev/null || return 0
  data="$(cat "$PEER_CACHE" 2>/dev/null || echo '{}')"
  jq -e . <<<"$data" >/dev/null 2>&1 || data='{}'
  if [[ -n "$payload" ]]; then
    entry="$(jq -cn --argjson p "$payload" --arg at "$(date '+%s')" \
              '{at:($at|tonumber),payload:$p}' 2>/dev/null || true)"
  else
    entry="$(jq -cn --arg at "$(date '+%s')" '{at:($at|tonumber),failed:true}' 2>/dev/null || true)"
  fi
  [[ -n "$entry" ]] || return 0
  data="$(jq -c --arg h "$host" --argjson e "$entry" '.[$h]=$e' <<<"$data" 2>/dev/null \
          || printf '%s' "$data")"
  printf '%s' "$data" > "$PEER_CACHE.tmp.$$" 2>/dev/null \
    && mv "$PEER_CACHE.tmp.$$" "$PEER_CACHE" || true
  return 0
}

# The payload for one host: cache first (either polarity), then ssh within the
# budget the STEP has left. Returns nothing at all on any failure, which is the
# whole contract.
peer_payload() {  # peer_payload <host> <budget-secs>
  local host="$1" budget="${2:-$PEER_TIMEOUT}" cached out payload rc=0
  cached="$(peer_cache_get "$host")" || rc=$?
  if (( rc == 0 )) && [[ -n "$cached" ]]; then
    peer_note "$host: reusing the cached payload (<${PEER_TTL}s old)"
    printf '%s' "$cached"; return 0
  fi
  if (( rc == 2 )); then
    peer_note "$host: failed within the last ${PEER_FAIL_TTL}s, not dialling it again yet (rm $(tilde "$PEER_CACHE") to retry now)"
    return 0
  fi
  # NOT a failure to record: we never dialled, so we learned nothing about this
  # peer. Recording it would let one slow box blacklist every box behind it.
  if (( budget <= 0 )); then
    peer_note "$host: skipped, the ${PEER_TIMEOUT}s peer budget is already spent"
    return 0
  fi
  out="$CFG_DIR/.peer.$$.json"
  mkdir -p "$CFG_DIR" 2>/dev/null || return 0
  if ! peer_ssh "$host" "$out" "$budget"; then
    rm -f "$out"; peer_cache_write "$host" ""; return 0
  fi
  # The peer's stdout can carry a routing note or a warning ahead of the object
  # (rota billing prints one when it reads another box), so take the JSON from the
  # first `{`, exactly as rota-billing.sh does with the engine's own output.
  payload="$(sed -n '/{/,$p' "$out" 2>/dev/null | jq -c 'select(type=="object")' 2>/dev/null | head -1 || true)"
  rm -f "$out"
  if [[ -z "$payload" ]]; then
    peer_note "$host: answered with something that is not JSON, ignoring it"
    peer_cache_write "$host" ""; return 0
  fi
  peer_cache_write "$host" "$payload"
  printf '%s' "$payload"
}

# ⚠️ A PERCENTAGE OFF ANOTHER MACHINE IS UNTRUSTED INPUT, and this is the one
# place peer data reaches bash ARITHMETIC. Unvalidated it was both a crash and a
# code-execution hole, both reproduced 2026-08-27 against a hostile payload:
#
#   "weekly_left_pct":"n/a"                 → `n: unbound variable`, exit 1, no
#                                             table and no JSON at all, breaking
#                                             both the degrade-quietly promise
#                                             above and `usage --json`'s "always
#                                             one parseable object"
#   "weekly_left_pct":"U_WKX[$(touch X)0]"  → exit 0, a normal-looking table, and
#                                             the command RAN. Bash evaluates array
#                                             subscripts inside $(( )), and `set -u`
#                                             only blocks the undefined-array
#                                             spelling, not a name that exists.
#   "85%" / "1e3" / true                    → all three abort the command
#
# The peer is semi-trusted at best: StrictHostKeyChecking=accept-new means a
# first-contact key (a re-imaged box, a LAN name takeover) is accepted silently,
# so "numbers from a box I trust" is not a guarantee the bytes came from it. One
# command as Cédric is a categorically different grant from reading percentages,
# and this feature is sold as read-only with nothing moving.
#
# Same guard remaining() has used all along, eight lines up. A value that is not a
# plain percentage is treated as THE PEER SUPPLIED NOTHING for that window, and the
# row falls through silently (R3), rather than being reported or guessed at.
peer_pct() {  # peer_pct <value> → the integer percentage it denotes, or nothing
  local v="${1:-}"
  [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 0
  v="${v%.*}"
  v=$((10#$v))                 # base ten, or a peer's "08" would be read as octal
  (( v > 100 )) && v=100       # clamp: a nonsense 100000 must not become -99900
  printf '%s' "$v"
}

# One peer row, \x1f-joined (never tab: see cache_get for why empty fields make
# tab-splitting silently shift every field left).
#
# BOTH payload shapes are accepted. `rota accounts --json` names the fields
# account / weekly_left_pct / weekly_resets_at, `rota usage --json` names them
# email / weekly.remaining_pct / weekly.resets_at, and which one answered depends
# on whether the peer had a billing.json. Neither shape is "the" shape, so the
# reader takes either rather than making the caller care.
#
# MATCH ON EMAIL, NEVER ON ALIAS. An alias is a per-box directory name: `work` on
# one box and `work` on another are not promised to be the same login, and a
# cross-matched row would put one seat's numbers on another seat's line.
peer_row() {  # peer_row <payload> <email>
  jq -r --arg e "$2" '
    ((.accounts // []) | map(select(((.account // .email) // "") == $e)))[0] // empty
    | [ (.weekly_left_pct     // .weekly.remaining_pct    // ""),
        (.weekly_resets_at    // .weekly.resets_at        // ""),
        (.five_hour_left_pct  // .five_hour.remaining_pct // ""),
        (.five_hour_resets_at // .five_hour.resets_at     // ""),
        (.quota_data          // .data                    // ""),
        (.quota_measured_at   // "") ]
    | map(tostring) | join("\u001f")' <<<"$1" 2>/dev/null || true
}

# THE PRECEDENCE (R4), and it is short on purpose:
#   1. a LIVE local fetch always wins, it is the freshest truth obtainable
#   2. otherwise the NEWER MEASUREMENT wins, local cache or peer, whichever
#      actually measured its number later
#   3. nothing → the row stays exactly as it was, `-` and [quota none]
#
# A number recorded by hand (`rota usage --record`, for the seats whose token the
# usage API answers 429 for) is a MEASUREMENT under rule 2 like any other: it
# reaches this function already adopted into the `cached` slot, carrying its
# read_at_epoch in U_AGE, so the same newer-wins test below arbitrates it with no
# special case. It is not privileged for having been typed and not demoted for it
# either; see the block above the human_get call in collect_usage.
#
# Peer numbers are deliberately NOT written into this box's usage-cache.json.
# That cache means "what THIS box measured"; seeding it from a peer would let a
# borrowed number come back next run wearing local clothes, with the provenance
# stripped off. The peer payload has its own cache with its own 90s TTL.
peer_fill() {
  local hosts host payload i email row deadline budget
  local p_wkl p_wkr p_sel p_ser p_state p_meas p_epoch l_epoch gen_epoch
  local p_pct p_uwk p_use
  local wanted=0
  (( NET )) || return 0            # --no-refresh means no network, and ssh is network
  (( PEER_SKIP )) && return 0      # a caller with its own budget said no
  (( PEER_TIMEOUT > 0 )) || return 0   # ROTA_PEER_TIMEOUT=0 = the step is off
  command -v jq >/dev/null 2>&1 || return 0
  command -v ssh >/dev/null 2>&1 || return 0
  # A box where every row is live never pays the round trip.
  for i in "${!DIRS[@]}"; do
    case "${U_STATE[$i]}" in none|cached) wanted=1; break ;; esac
  done
  (( wanted )) || return 0
  hosts="$(peer_hosts)"
  [[ -n "$hosts" ]] || return 0
  peer_tmp_sweep

  # ── THE BOUND IS ON THE STEP, NOT ON THE DIAL ──────────────────────────────
  # One deadline for the whole peer step, computed once. Each dial gets whatever
  # is LEFT of it (never more than PEER_TIMEOUT), and a peer reached after the
  # budget is spent is skipped rather than dialled. Before this the watchdog sat
  # inside peer_ssh, which runs once per host, so three hanging peers cost
  # 3 × PEER_TIMEOUT (~30s at the default) while the spec, and the operator
  # waiting at a prompt, were promised ~10s for the lot. config/peers.example
  # invites a list, so this was reachable as shipped, not theoretical.
  #
  # A CACHED payload still counts, budget or no budget: peer_payload only gates
  # the dial, so a peer whose answer is already on disk keeps contributing after
  # a slow box ahead of it has eaten the clock.
  deadline=$(( $(date '+%s') + PEER_TIMEOUT ))

  while read -r host; do
    [[ -n "$host" ]] || continue
    budget=$(( deadline - $(date '+%s') ))
    (( budget > PEER_TIMEOUT )) && budget="$PEER_TIMEOUT"
    payload="$(peer_payload "$host" "$budget")"
    [[ -n "$payload" ]] || continue
    gen_epoch="$(iso_epoch "$(jq -r '.generated_at // empty' <<<"$payload" 2>/dev/null || true)")"
    local used_any=0
    for i in "${!DIRS[@]}"; do
      case "${U_STATE[$i]}" in none|cached) ;; *) continue ;; esac
      email="${U_EMAIL[$i]}"
      [[ -n "$email" ]] || continue
      row="$(peer_row "$payload" "$email")"
      [[ -n "$row" ]] || continue
      IFS=$'\x1f' read -r p_wkl p_wkr p_sel p_ser p_state p_meas <<<"$row"
      # VALIDATED here, before anything numeric happens to them, see peer_pct
      p_uwk=""; p_use=""
      p_pct="$(peer_pct "$p_wkl")"; [[ -n "$p_pct" ]] && p_uwk="$((100 - p_pct))"
      p_pct="$(peer_pct "$p_sel")"; [[ -n "$p_pct" ]] && p_use="$((100 - p_pct))"
      # a peer row with no usable numbers of its own (its own box could not measure
      # that seat either, or it sent something that is not a percentage) is not an
      # answer, it is the same blank in someone else's hand
      [[ -n "$p_uwk$p_use" ]] || continue
      [[ "$p_state" == "dup" ]] && continue
      # R4: peer freshness is the row's own measurement instant when the peer
      # publishes one, and the payload's generated_at when it does not (an older
      # peer that predates quota_measured_at). generated_at is the optimistic
      # reading of the two, so it is the fallback, never the preference.
      p_epoch="$(iso_epoch "$p_meas")"
      [[ "$p_epoch" =~ ^[0-9]+$ ]] || p_epoch="$gen_epoch"
      if [[ "${U_STATE[$i]}" == "cached" ]]; then
        l_epoch="${U_AGE[$i]:-}"
        # a local cache row we cannot date loses to a peer row we can, and vice
        # versa; two undatable rows leave the local one in place (do no harm)
        if [[ "$l_epoch" =~ ^[0-9]+$ ]] && [[ "$p_epoch" =~ ^[0-9]+$ ]]; then
          (( p_epoch > l_epoch )) || continue
        elif [[ ! "$p_epoch" =~ ^[0-9]+$ ]]; then
          continue
        fi
      fi
      U_STATE[i]="peer"
      U_SRC[i]="$host"
      # the peer publishes % LEFT; this file stores % USED (the API's utilization),
      # so it was inverted back on the way in (above, after validation) and
      # remaining() returns the same integer the peer printed
      U_WKU[i]="$p_uwk"; U_SEU[i]="$p_use"
      U_WKR[i]="$p_wkr"; U_SER[i]="$p_ser"; U_SDR[i]="$p_wkr"
      # the peer publishes the binding NUMBER but not which limit produced it, so
      # the row carries no scope annotation rather than a borrowed or invented one
      U_WKK[i]=""; U_WKS[i]=""
      U_WKX[i]=0; U_SEX[i]=0
      window_expired "$p_wkr" && U_WKX[i]=1
      window_expired "$p_ser" && U_SEX[i]=1
      # the projection follows whatever weekly numbers the row ENDS UP with, so it
      # is recomputed wherever they are replaced: a peer that answered with a real
      # reset must clear a projection this box had made, or the row would publish
      # both a measured instant and an inferred one.
      project_weekly "$i"
      U_TS[i]=""; U_AGE[i]=""; U_MEAS[i]=""
      if [[ "$p_epoch" =~ ^[0-9]+$ ]]; then
        U_AGE[i]="$p_epoch"; U_MEAS[i]="$(epoch_iso "$p_epoch")"
      fi
      U_VIA[i]="numbers read from $host over ssh; no credential moved, this box never held one for this seat"
      used_any=1
    done
    if (( used_any )); then
      PEER_HOST="$host"
      PEER_GENERATED="$(jq -r '.generated_at // empty' <<<"$payload" 2>/dev/null || true)"
      peer_note "$host: filled in the rows this box could not measure"
      return 0            # first peer that answers usefully wins
    fi
    peer_note "$host: answered, but had nothing this box is missing"
  done <<<"$hosts"
  return 0
}

# ── collect usage for every slot, at most one fetch per token ────────────────
# Fills, per slot index i:
#   U_EMAIL[i]  the account that slot's own config JSON says it is
#   U_STATE[i]  live | cached | peer | none | dup
#   U_WKU/U_WKR/U_SEU/U_SER[i]   utilization + reset instant, per window. The weekly
#               pair is the BINDING weekly limit (see weekly_binding), falling back to
#               seven_day when the response carries no usable `limits` array.
#   U_WKK/U_WKS[i]               the binding weekly limit's kind and scope name, both
#               empty on the seven_day fallback and on an unscoped binding limit
#   U_SDR[i]    seven_day/weekly_all resets_at, kept RAW for the identity fingerprint,
#               that comparison is only meaningful between the same kind of window, so
#               it must not follow whichever kind happens to bind
#   U_WKP/U_WKPF[i]              the PROJECTED weekly reset and the seen instant it
#               was rolled forward from, both empty unless the API named no reset at
#               all for a window that is neither expired nor unmeasured. Never mixed
#               into U_WKR: see project_weekly for why an inference keeps its own pair
#   U_WKX/U_SEX[i]               1 when a CACHED window has already reset
#   U_WHY[i]    why it isn't live (shown, and quoted in the exclusion reason)
#   U_TS[i]     cache stamp for a cached row
#   U_VIA[i]    provenance note (e.g. numbers taken from the live shared credential)
#   U_DUP[i]    index of the earlier slot holding the same account, or -1
#   U_SRC[i]    the PEER these numbers were read from, "" when they are this box's own
#   U_MEAS[i]   WHEN this row's numbers were actually measured (UTC ISO), which is
#               not the same question as when the report was generated. A live row
#               was measured this run; a cached row was measured whenever the cache
#               says; a peer row was measured on the peer, possibly days ago. Every
#               surface that prints an age reads this, so "how old is this number"
#               has exactly one answer per row.
# Plus the shared ~/.claude credential's own row in S_*.
# ── seat lifecycle: read once, keyed by email ────────────────────────────────
#
# seat_field <email> 1 -> active|cancelled ;  seat_field <email> 2 -> YYYY-MM-DD end date
#
# ⚠️ THE READER ITSELF LIVES IN rota-ranking.sh, so the keeper reads the seat
# lifecycle out of the same file, in the same shape, with the same
# missing-file behaviour. These two are thin BINDINGS of that reader to this
# script's own $BILLING_JSON; every call site below is unchanged.
load_seats() { rota_load_seats "$BILLING_JSON"; }
seat_field() { rota_seat_field "$BILLING_JSON" "${1:-}" "${2:-}"; }

# Has the seat itself ENDED? This is the ONLY one of the three states that means
# "this account is finished", and it is a date comparison, never an inference
# from a stale number.
seat_ended() {  # seat_ended <slot-index>
  load_seats
  local e="${U_EMAIL[$1]:-}" ends
  [[ -n "$e" ]] || return 1
  ends="$(seat_field "$e" 2)"
  [[ -n "$ends" ]] || return 1
  [[ "$ends" < "$(date '+%Y-%m-%d')" ]]
}

# Temporary limit changes the vendor announces on its own site and no API
# reports.
#
# ⚠️ A PERCENTAGE IS ONLY MEANINGFUL AGAINST A KNOWN BASELINE, AND THE BASELINE
# MOVES. Weekly Claude Code limits were 50% higher through 2026-08-31, so "40%
# left" during that window is more absolute quota than "40% left" after it, and
# any plan made against a remembered baseline is wrong for as long as the boost
# runs. There is no API field for it, so it is read off the vendor's usage page
# and written into billing.json.
#
# Each entry carries its own `through` date and is simply not printed once that
# date passes, so a boost that ends cannot linger as a false footnote, the
# failure mode a hard-coded sentence would have had.
render_boosts() {
  [[ -r "$BILLING_JSON" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local today line
  today="$(date '+%Y-%m-%d')"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf '  %s\n' "$(paint "$CLR_YELLOW" "$line")"
  done < <(jq -r --arg today "$today" \
      '(.boosts // [])[] | select(.through >= $today)
       | "boost until \(.through): \(.what)"' "$BILLING_JSON" 2>/dev/null || true)
  return 0
}

seat_ends_on() { seat_field "${U_EMAIL[$1]:-}" 2; }
seat_cancelled() { [[ "$(seat_field "${U_EMAIL[$1]:-}" 1)" == "cancelled" ]]; }

# ⚠️ A CANCELLED SEAT IS THE MOST USE-IT-OR-LOSE-IT QUOTA IN THE POOL, NOT THE
# LEAST. It has a fixed number of weekly windows left, ever: after its end date
# that quota is gone whether it was spent or not. So the deadline that ranks a
# row is min(weekly reset, seat end), not the weekly reset alone, and a
# cancelled seat with NO measured weekly window still has a real deadline rather
# than falling to the "nothing is expiring" tier.
#
# ⚠️ THE RULE IS NOT WRITTEN HERE. rota_seat_deadline (rota-ranking.sh) owns it,
# so rota-keeper.sh's unattended picker cannot rank a seat differently from the
# surface that told the operator what to do. Do not re-inline the comparison, and
# do not "simplify" either copy back to the weekly reset alone; that is the older
# rule, it agrees with this one almost always, and it is wrong exactly on a
# cancelled seat's last partial week.
#
# This is the SLOT-INDEXED binding of it: it looks the two dates up for a row and
# passes the pair through. Answers "<deadline-iso>\t<reset|seat-end>", because the
# sentence a surface prints has to be able to name WHICH date bound the choice.
#
# ⚠️ A PROJECTED RESET IS STILL A DEADLINE. An untouched weekly window loses its
# whole allowance on the same fixed cadence as a spent one, so ranking it as "no
# deadline at all" (rota_deadline_beats sinks those LAST) sent the operator to a
# seat resetting Monday while an untouched one lost its week on Saturday. The
# measured instant always wins; the projection is the fallback, never a blend.
seat_deadline() {  # seat_deadline <slot-index> -> "<ISO instant>\t<reset|seat-end>", or "\t"
  local wk="${U_WKR[$1]:-}"
  [[ -n "$wk" ]] || wk="${U_WKP[$1]:-}"
  rota_seat_deadline "$wk" "$(seat_ends_on "$1")"
}

# ── what a human read off the vendor's usage page, because the API would not ──
#
# billing.json's header states the principle this follows: "THIS file holds the
# half that no API exposes". A measurement is the same KIND of fact when the API
# refuses, but it is per-machine and it PERISHES, so it lives beside the usage
# cache in $CFG_DIR rather than in billing.json, where a hand-typed number
# copied between machines would read as measured.
HUMAN_USAGE="${CLAUDE_HUMAN_USAGE:-$CFG_DIR/human-usage.json}"
H_WKU=""; H_WKR=""; H_SEU=""; H_SER=""; H_TS=""; H_TE=""
human_get() {  # human_get <email>
  H_WKU=""; H_WKR=""; H_SEU=""; H_SER=""; H_TS=""; H_TE=""
  [[ -r "$HUMAN_USAGE" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local row
  # ⚠️ UNIT SEPARATOR, NOT TAB. Tab is IFS *whitespace*, so bash collapses a run
  # of them into ONE delimiter, and this row has two fields that are routinely
  # empty (no 5h reading). With @tsv the timestamp shifted into the 5h slot and
  # the row rendered as `[cached ]` with no date: a hand-typed measurement that
  # looked like it had no age at all, which is precisely the dishonesty this
  # whole change exists to remove. \x1f is not whitespace, so empty fields hold
  # their place. Same rule, same reason, as cache_get above.
  row="$(jq -r --arg e "$1" '(.accounts // {})[$e]
          | if . == null then empty
            else [(.weekly_used//""),(.weekly_resets_at//""),(.five_hour_used//""),
                  (.five_hour_resets_at//""),(.read_at//""),(.read_at_epoch//"")]
                 | map(tostring) | join("\u001f") end' "$HUMAN_USAGE" 2>/dev/null || true)"
  [[ -n "$row" ]] || return 0
  IFS=$'\x1f' read -r H_WKU H_WKR H_SEU H_SER H_TS H_TE <<<"$row"
  return 0
}

# `rota usage --record <alias> <weekly-used-%> [<5h-used-%>]`
#
# The numbers are the ones the vendor's usage page prints, in the polarity that
# page prints them (USED, not left): asking somebody to invert a number they are
# copying off a screen is how a typo becomes a wrong decision.
#
# ⚠️ IT STAMPS THE WEEKLY WINDOW IT BELONGS TO, so it expires on its own. A
# measurement with no window is indistinguishable from a fresh one forever,
# which is the exact defect this whole change is about, a number outliving the
# window it described. Absent a stated reset, the window is assumed to end seven
# days from now, and `window_expired` retires it after that like any other.
record_human_usage() {  # record_human_usage <alias> <weekly-used> [<5h-used>] [<weekly-reset-iso>]
  local alias="${1:-}" wk="${2:-}" se="${3:-}" wkr="${4:-}"
  [[ -n "$alias" && -n "$wk" ]] || die "usage --record needs a seat alias and the weekly USED %, e.g. \`rota usage --record spare 12\`"
  [[ "$wk" =~ ^[0-9]+$ ]] && (( wk <= 100 )) || die "weekly USED % must be 0-100, got '$wk'"
  [[ -z "$se" || ( "$se" =~ ^[0-9]+$ && "$se" -le 100 ) ]] || die "5h USED % must be 0-100, got '$se'"
  local dir="$POOL_ROOT/$alias" email
  [[ -d "$dir" ]] || die "no pool dir at $(tilde "$dir"), is '$alias' a real seat alias?"
  email="$(config_email "$dir")"
  [[ -n "$email" ]] || die "cannot tell which account $(tilde "$dir") holds"
  [[ -n "$wkr" ]] || wkr="$(date -u -v+7d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
                            || date -u -d '+7 days' '+%Y-%m-%dT%H:%M:%SZ')"
  mkdir -p "$CFG_DIR"
  [[ -s "$HUMAN_USAGE" ]] || printf '{"_comment":"Usage percentages a human read off the vendor usage page, for seats whose token the usage API will not answer for. Percentages are USED, as that page prints them. Each entry carries the window it belongs to and is ignored once that window has passed.","accounts":{}}\n' > "$HUMAN_USAGE"
  local tmp; tmp="$(mktemp "$HUMAN_USAGE.XXXXXX")"
  jq --arg e "$email" --argjson wk "$wk" \
     --argjson se "$( [[ -n "$se" ]] && printf '%s' "$se" || printf 'null' )" \
     --arg wkr "$wkr" --arg ts "$(date '+%b %-d %H:%M')" \
     --argjson te "$(date '+%s')" \
     '.accounts[$e] = {weekly_used:$wk, weekly_resets_at:$wkr,
                       five_hour_used:$se, five_hour_resets_at:null,
                       read_at:$ts, read_at_epoch:$te,
                       source:"vendor usage page, read by hand"}' \
     "$HUMAN_USAGE" > "$tmp" && mv "$tmp" "$HUMAN_USAGE"
  printf 'recorded for %s: weekly %s%% used, window until %s\n' "$email" "$wk" "$wkr"
  printf '  it feeds `rota usage` only while that window lasts, and only when the API will not answer.\n'
  # shellcheck disable=SC2016  # literal backticks, nothing to expand
  printf '  a peer that measured this seat MORE RECENTLY still wins; the newer measurement always does.\n'
}

# Is this row's WEEKLY quota simply UNKNOWN? Either the cached window has since
# rolled (so the number describes a window that no longer exists) or the usage
# API refused to answer at all, the 429 case, which on a busy pool host is the
# norm and not a blip.
#
# ⚠️ Measured 2026-08-21 09:35 on the pool host: GET /api/oauth/usage returned
# HTTP 429 for both cancelled seats across six attempts over two and a half
# minutes, with no live session on either and a valid credential in every pool
# dir. The row's own note says "retry in ~1 min, live sessions share this
# token"; that is not what is happening here, and no retry loop rescues it. So
# "unknown" has to be a state the report can show honestly, not a transient to
# be papered over.
# ⚠️ NARROW ON PURPOSE, "unknown" IS NOT "unusable". The first cut of this asked
# only "is there a weekly number", which swept in every row whose CREDENTIAL is
# the problem: no stored credential, one the CLI cleared, a refresh already
# rejected. Those accounts really are unavailable, they need a login before
# anybody can spend them, and inviting a measurement is useless advice. Seven
# tests caught it, and they were right to.
#
# So this is exactly the two facts the 2026-08-21 measurement established: a
# cached window that has ROLLED (the number describes a window that no longer
# exists) and a usage API that answered 429. In both, the seat is fine and only
# the NUMBER is missing.
#
# ⚠️ "MISSING" MEANS MISSING FROM THE REPORT, NOT MISSING FROM THIS BOX'S OWN
# PROBE, and that distinction only started to matter when peer rows arrived
# (2026-08-27). U_WHY answers "why did THIS box fail to fetch", and after
# peer_fill a row can carry a 429 in U_WHY and, at the same time, a real
# current-window number that a peer measured over ssh. Asking U_WHY alone then
# filed a perfectly good borrowed number under UNMEASURED, which prints no
# number at all and tells the operator to go and read one off the vendor's page:
# the exact inversion this bucket exists to prevent, pointing the other way.
#
# So the question is asked about the ROW, not about the probe. In order:
#   1. the window this row's number describes has ROLLED  -> unknown, whoever
#      measured it (local cache, a peer, or a hand reading): the number is about
#      a window that no longer exists
#   2. there IS a number for the CURRENT window           -> measured. Where it
#      came from is a freshness question the state tag already answers
#      (`cached Mon 14:02`, `via ballito, 2d old`), never a bucket question
#   3. no number, and the probe was REFUSED (429)         -> unknown
#   4. no number, and the CREDENTIAL is the problem       -> not unknown, see the
#      "narrow on purpose" note above: that seat needs a login, not a measurement
weekly_unknown() {  # weekly_unknown <slot-index>
  (( U_WKX[$1] == 1 )) && return 0
  [[ -n "${U_WKU[$1]:-}" ]] && return 1
  case "${U_WHY[$1]:-}" in
    # an EXPIRED access token (refresh token still in date) is the same shape: the
    # seat is fine, only the number is missing, and a login is NOT the fix, one
    # session (or the nudge) is. Listed before 429 because its reason string
    # quotes the HTTP code the vendor answered with.
    *'access token expired'*) return 0 ;;
    *429*) return 0 ;;
  esac
  return 1
}

NET=1                      # 0 = --no-refresh: cache only, never touch the network
RUN_MEASURED_AT=""         # UTC ISO instant this pass's LIVE numbers were measured
COLLECTED=0
COLLECTED_NET=0            # was the completed collection allowed to use the network?
SHARED_TWIN_SLOT=-1        # slot whose credential bytes are identical to the shared one
S_JSON=""; S_HTTP=""; S_WKU=""; S_WKR=""; S_SEU=""; S_SER=""
S_WKK=""; S_WKS=""; S_SDR=""
collect_usage() {
  (( COLLECTED )) && return 0
  COLLECTED=1
  COLLECTED_NET="$NET"     # remembered so ensure_fresh_usage can tell a cache-only
                           # pass (resolve_shared_identity --auto forces one) from a
                           # networked one, instead of letting the COLLECTED guard
                           # freeze cache-only rows in for the rest of the run
  command -v jq >/dev/null 2>&1 || die "usage needs jq"
  local i j
  # ONE stamp for the whole pass, taken before the first fetch: every row that
  # comes back live this run was measured at (near enough) this instant, and
  # re-reading the clock per row would publish N slightly different answers to a
  # question that has one.
  RUN_MEASURED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  PEER_HOST=""; PEER_GENERATED=""
  U_EMAIL=(); U_STATE=(); U_WKU=(); U_WKR=(); U_SEU=(); U_SER=()
  U_WKX=(); U_SEX=(); U_WHY=(); U_TS=(); U_VIA=(); U_DUP=()
  U_WKK=(); U_WKS=(); U_SDR=(); U_SRC=(); U_MEAS=(); U_WKP=(); U_WKPF=()
  for i in "${!DIRS[@]}"; do
    U_EMAIL[i]=""; U_STATE[i]="none"; U_WKU[i]=""; U_WKR[i]=""; U_SEU[i]=""; U_SER[i]=""
    U_WKX[i]=0; U_SEX[i]=0; U_WHY[i]=""; U_TS[i]=""; U_VIA[i]=""; U_DUP[i]=-1
    U_WKK[i]=""; U_WKS[i]=""; U_SDR[i]=""; U_AGE[i]=""; U_SRC[i]=""; U_MEAS[i]=""
    U_WKP[i]=""; U_WKPF[i]=""
  done

  # the shared credential FIRST: it is both the identity fingerprint and the row
  # whose numbers matter most, and it is the token most likely to be rate-limited
  local shared_cred="$HOME/.claude/.credentials.json"
  if (( NET )); then
    usage_fetch "$(cred_token "$HOME/.claude")"; S_JSON="$USAGE_JSON"; S_HTTP="$USAGE_HTTP"
    if [[ -n "$S_JSON" ]]; then
      S_WKU="$(usage_field "$S_JSON" '.seven_day.utilization')"
      S_WKR="$(usage_field "$S_JSON" '.seven_day.resets_at')"
      S_SEU="$(usage_field "$S_JSON" '.five_hour.utilization')"
      S_SER="$(usage_field "$S_JSON" '.five_hour.resets_at')"
      S_SDR="$S_WKR"
      weekly_binding "$S_JSON"
      if [[ -n "$WB_PCT" ]]; then
        S_WKU="$WB_PCT"; S_WKR="$WB_RESET"; S_WKK="$WB_KIND"; S_WKS="$WB_SCOPE"
        # same fallback, same reason, as the per-slot block below
        [[ -n "$S_WKR" ]] || S_WKR="$WB_ALL_RESET"
        [[ -n "$S_SDR" ]] || S_SDR="$WB_ALL_RESET"
      fi
    fi
  fi

  for i in "${!DIRS[@]}"; do
    local adir="${DIRS[$i]}" alabel="${LABELS[$i]}" email
    email="$(config_email "$adir")"; [[ -n "$email" ]] || email="$alabel"
    U_EMAIL[i]="$email"
    # one fetch per ACCOUNT too: two slots can point at the same login
    for ((j = 0; j < i; j++)); do
      if [[ "${U_EMAIL[$j]}" == "$email" ]] && (( U_DUP[j] < 0 )); then U_DUP[i]=$j; break; fi
    done
    if (( U_DUP[i] >= 0 )); then U_STATE[i]="dup"; continue; fi

    # v2: shared slot is credential-free / stashes are read-only history, the
    # v1 SELF-HEAL ON READ (heal_pool_credential, 2026-08-07) is short-circuited
    # here (stage-1 review, 2026-08-12): a stash-restore MOVES credential bytes,
    # which violates invariant 1, and a restored-but-stale credential is exactly
    # what triggers a spurious nudge→husk cycle. A gutted pool copy now reports
    # "needs a re-login" instead of being silently rewritten; the function stays
    # for reference and for the guard rules it documents.

    local json="" http="" token="" credfile="$adir/.credentials.json"
    local tok_expired_ago=""   # reset per slot: it feeds the reason below, whichever branch ran
    token="$(cred_token "$adir")"
    if [[ -z "$token" ]]; then
      # NAME THE REAL DEFECT. On 2026-08-07 a gutted file reported "no stored
      # credential", and that one phrase sent the operator hunting for a login that had
      # already happened. A file that EXISTS but has been cleared is not a missing
      # login, it is a REVOKED one, and the only fix is a re-login, so it says that.
      if [[ ! -e "$credfile" ]]; then
        U_WHY[i]="no stored credential, log it in once with CLAUDE_CONFIG_DIR=$(tilde "$adir") claude"
      elif ! cred_is_complete "$credfile"; then
        U_WHY[i]="stored credential was CLEARED (gutted file at $(tilde "$credfile"): no refresh token/expiry left), a rejected refresh does this; needs a re-login: CLAUDE_CONFIG_DIR=$(tilde "$adir") claude"
      else
        U_WHY[i]="no stored credential, log it in once with CLAUDE_CONFIG_DIR=$(tilde "$adir") claude"
      fi
    elif [[ -f "$shared_cred" ]] && cmp -s "$credfile" "$shared_cred"; then
      # byte-identical to the LIVE shared credential: same token, so reuse the fetch
      # already spent on it instead of burning a second rate-limit slot. This is also
      # the strongest identity evidence there is.
      SHARED_TWIN_SLOT="$i"
      json="$S_JSON"; http="$S_HTTP"
      U_VIA[i]="same credential as the shared ~/.claude"
      (( NET )) || U_WHY[i]="--no-refresh: cached numbers only"
    elif (( ! NET )); then
      U_WHY[i]="--no-refresh: cached numbers only"
    else
      usage_fetch "$token"; json="$USAGE_JSON"; http="$USAGE_HTTP"
      # ⚠️ A 429 ON AN ALREADY-EXPIRED TOKEN IS NOT RATE LIMITING. Measured on the
      # pool host 2026-08-30 (150s quiet before each call, no live session on the
      # seat): the usage API answered 429 to a real access token five days past its
      # expiresAt, and 401 to a garbage one. Nothing can be "sharing" a token that
      # expired days ago, so the 429 skip below must not fire for it: that skip is
      # what left four of five seats UNMEASURED for up to five days (2026-08-25 →
      # 08-30) while the row promised "retry in ~1 min". The nudge is the one path
      # that rotates a stored token, and it is exactly what an expired one needs.
      tok_expired_ago="$(cred_token_expired_ago "$credfile")"
      if [[ -z "$json" ]] && { [[ "$http" != "429" ]] || [[ -n "$tok_expired_ago" ]]; }; then
        # a stored token only rotates when a session USES the account, so spend one
        # haiku token, the CLI refreshes + persists the credential itself. cwd=/ plus
        # this exact prompt marks the run as a synthetic session, so anything that
        # mines transcripts can tell these nudges apart from real work. (Skipped on a
        # 429 for a token still IN DATE: that is per-token rate limiting on the usage
        # API, not a stale token.)
        #
        # ⚠ THIS IS THE WRITE THAT GUTTED THE PERSONAL SEAT ON 2026-08-07, see the header block.
        # The nudge only ever runs for an account whose token is already stale, which
        # is precisely the account whose refresh token might be dead; when it is, the
        # CLI clears the credential rather than leaving one it cannot use. There is no
        # way to tell a stale-but-refreshable token from a dead one WITHOUT trying, so
        # the rule is: try once, watch what it did to the file, and never try that same
        # credential again.
        local pre_complete=0 pre_fp=""
        cred_is_complete "$credfile" && pre_complete=1
        pre_fp="$(cred_fingerprint "$credfile" 2>/dev/null || true)"
        if seat_is_reserved "$alabel" "$adir" && [[ "${ROTA_NUDGE_RESERVED:-0}" != "1" ]]; then
          # somebody else's seat: its refresh chain is also held on the owner's box
          # (the Airmond runner, Joe's laptop), and a nudge from here rotates the
          # chain out from under that copy. Say why it is unmeasured and who answers.
          U_WHY[i]="reserved seat, not nudged from this box (its owner's machine rotates the token)${tok_expired_ago:+; stored access token expired $tok_expired_ago ago}; rota usage --record $(basename "$adir") <weekly-used-%> answers it, ROTA_NUDGE_RESERVED=1 overrides"
        elif (( pre_complete )) && refresh_known_dead "$alabel" "$credfile"; then
          # already watched this exact credential's refresh be rejected. Nudging it
          # again cannot succeed and CAN destroy it; the answer is a re-login.
          U_WHY[i]="refresh already rejected, this stored credential is dead and needs a re-login: CLAUDE_CONFIG_DIR=$(tilde "$adir") claude"
        else
          (cd / && CLAUDE_CONFIG_DIR="$adir" claude -p "Reply with exactly the word: ok" --model claude-haiku-4-5-20251001 >/dev/null 2>&1) || true
          if (( pre_complete )) && ! cred_is_complete "$credfile"; then
            # complete going in, gutted coming out: the refresh was rejected and the
            # CLI cleared the credential. Remember it so the next run neither nudges
            # nor re-heals these same dead bytes, and name the only real fix.
            mark_refresh_dead "$alabel" "$pre_fp"
            printf '%s: the refresh token was rejected and the CLI CLEARED the stored credential at %s, this account needs a re-login (CLAUDE_CONFIG_DIR=%s claude), no restore can fix it\n' \
              "$alabel" "$(tilde "$credfile")" "$(tilde "$adir")" >&2
            U_WHY[i]="refresh rejected, the CLI cleared the stored credential; needs a re-login: CLAUDE_CONFIG_DIR=$(tilde "$adir") claude"
          fi
          token="$(cred_token "$adir")"
          if [[ -n "$token" ]]; then usage_fetch "$token"; json="$USAGE_JSON"; http="$USAGE_HTTP"; fi
        fi
      fi
    fi

    if [[ -n "$json" ]]; then
      U_WKU[i]="$(usage_field "$json" '.seven_day.utilization')"
      U_WKR[i]="$(usage_field "$json" '.seven_day.resets_at')"
      U_SEU[i]="$(usage_field "$json" '.five_hour.utilization')"
      U_SER[i]="$(usage_field "$json" '.five_hour.resets_at')"
      U_SDR[i]="${U_WKR[$i]}"
      # the BINDING weekly limit wins over seven_day whenever `limits` yields one, a
      # scoped per-model cap above weekly_all is the wall you actually hit
      weekly_binding "$json"
      if [[ -n "$WB_PCT" ]]; then
        U_WKU[i]="$WB_PCT"; U_WKR[i]="$WB_RESET"
        U_WKK[i]="$WB_KIND"; U_WKS[i]="$WB_SCOPE"
        # ⚠️ A SCOPED CAP SHARES THE SEAT'S WEEKLY CADENCE, so weekly_all's instant
        # is this same window's, not a borrowed one. The vendor omits a scoped
        # entry's own resets_at while that scoped utilization is 0, and the scoped
        # entry can still BIND (percent ties go to it), so without this a seat with
        # real weekly usage was published with no reset at all - the second, quieter
        # route to the same "weekly reset unknown" defect project_weekly exists for.
        [[ -n "${U_WKR[$i]}" ]] || U_WKR[i]="$WB_ALL_RESET"
        [[ -n "${U_SDR[$i]}" ]] || U_SDR[i]="$WB_ALL_RESET"
      fi
      if [[ -z "${U_WKU[$i]}${U_SEU[$i]}" ]]; then
        # schema differs from expectation, surface the real keys (usage data is not secret)
        echo "  [$alabel] unexpected usage schema; top-level keys: $(printf '%s' "$json" | jq -r 'keys|join(",")' 2>/dev/null)" >&2
        U_WHY[i]="unexpected usage schema"
      else
        U_STATE[i]="live"
        U_MEAS[i]="$RUN_MEASURED_AT"
        # BEFORE cache_put's flush, deliberately: project_weekly reads the row on
        # disk, which still holds the PREVIOUS reading, and that is exactly the
        # instant a fresh window has to be projected from.
        project_weekly "$i"
        cache_put "$email" "${U_WKU[$i]}" "${U_WKR[$i]}" "${U_SEU[$i]}" "${U_SER[$i]}"
        continue
      fi
    fi

    # not live → fall back to the last-good cached numbers, age-marked, with any
    # window that has since reset shown as expired rather than as a number
    if [[ -z "${U_WHY[$i]}" ]]; then
      if [[ -n "$tok_expired_ago" ]]; then
        # the honest reason, whatever code the vendor used to refuse the token; and
        # the honest next step: only a session on this seat (or the nudge above,
        # which just ran) rotates it. "retry in ~1 min" was never going to come true.
        U_WHY[i]="stored token is stale (access token expired ${tok_expired_ago} ago, usage API answered HTTP ${http:-none}), nothing rotates it while no session runs on this seat"
      elif [[ "$http" == "429" ]]; then
        U_WHY[i]="usage API 429, retry in ~1 min, live sessions share this token"
      else
        U_WHY[i]="stored token is stale (HTTP ${http:-none}), the CLI only rotates it when a session uses this account"
      fi
    fi
    cache_get "$email"
    # ⚠️ A HAND-READ MEASUREMENT OUTRANKS AN EXPIRED CACHE, AND ONLY AN EXPIRED
    # ONE. On a busy pool host the usage API answers 429 far more often than it
    # answers (measured 2026-08-21: six attempts over two and a half minutes,
    # both cancelled seats, no live session on either, a valid credential in
    # every pool dir), so for some seats there is no automated path to the
    # number at all, while the number itself is two clicks away on the vendor's
    # usage page. `rota usage --record` stores what a human read there; this is
    # where it is used.
    #
    # It never displaces a LIVE fetch and never displaces a cache that is still
    # describing its own window: a typed number is the answer of last resort,
    # not a preference.
    #
    # ⚠️ AND AGAINST A PEER ROW (2026-08-27, the question `--record` predates):
    # THE NEWER MEASUREMENT WINS, which is R4, unchanged, applied to one more
    # kind of measurement. A hand reading lands in the `cached` slot below with
    # its read_at_epoch in U_AGE, so peer_fill's own newer-wins comparison
    # arbitrates it exactly as it arbitrates this box's cache. Deliberately no
    # privilege in either direction:
    #   - typed a minute ago, peer's payload is a day old -> the typed number
    #     wins, which is the whole reason it was typed
    #   - peer measured this seat live 30s ago, the typed number is yesterday's
    #     -> the peer wins, and should: it is an API reading of the same seat
    # The one asymmetry is already handled above by window, not by source: a
    # hand reading whose window has rolled is dropped here before it is ever
    # adopted, because `--record` stamps a window precisely so it can expire.
    if [[ -z "$json" ]] && { [[ -z "$C_WKU$C_SEU" ]] || window_expired "$C_WKR"; }; then
      human_get "$email"
      if [[ -n "$H_WKU" ]] && ! window_expired "$H_WKR"; then
        C_WKU="$H_WKU"; C_WKR="$H_WKR"; C_SEU="$H_SEU"; C_SER="$H_SER"
        C_TS="$H_TS"; C_TE="$H_TE"
        U_VIA[i]="read off the vendor usage page by hand $H_TS, the usage API would not answer"
      fi
    fi
    if [[ -n "$C_WKU$C_SEU" ]]; then
      U_STATE[i]="cached"
      U_WKU[i]="$C_WKU"; U_WKR[i]="$C_WKR"; U_SEU[i]="$C_SEU"; U_SER[i]="$C_SER"
      # the cache stores the binding NUMBER but not which limit produced it, so a cached
      # row carries no scope annotation rather than a stale or invented one
      U_WKK[i]=""; U_WKS[i]=""; U_SDR[i]="$C_WKR"
      U_TS[i]="$C_TS$(cache_age "$C_TE")"
      U_AGE[i]="$C_TE"
      # ts_epoch is when the number was MEASURED, which is the only honest answer
      # to "how old is this". Older cache files carry only the human stamp; those
      # rows publish no measured_at rather than a guessed one.
      U_MEAS[i]="$(epoch_iso "$C_TE")"
      window_expired "$C_WKR" && U_WKX[i]=1
      window_expired "$C_SER" && U_SEX[i]=1
      # LAST in this branch: project_weekly re-reads the cache (clobbering the C_*
      # globals), so every value this row needs from them is already copied out.
      project_weekly "$i"
    else
      U_STATE[i]="none"
    fi
  done
  # LAST, and only for the rows still blank or still cached: everything above is
  # what this box can measure itself, and a local live fetch outranks any peer.
  # Deliberately before cache_flush only in reading order, it queues nothing.
  peer_fill
  cache_flush
  return 0   # the loop can end on a false window_expired test, never leak that as a failure
}

# ── the ONE stale-input guard, shared by the dashboard and switch-auto ───────
# Before this, only the dashboard path went through a networked collection with any
# intent behind it; switch-auto simply called collect_usage and then hard-excluded
# every row that came back cached. On 2026-08-05 that combination dead-ended: every
# stored token was stale, every row fell back to a cache from 2026-07-20, every row
# was excluded as "no LIVE numbers", and the no-argument switch, whose entire job is
# to spare the operator the choice, refused to choose and told him to name an account.
#
# Two pieces, deliberately factored so both callers use the same test:
#   usage_row_stale     is THIS row's data something other than a live fetch from
#                       this run? (a `dup` row has no numbers of its own, so it is
#                       not stale, it is just a duplicate)
#   ensure_fresh_usage  the refresh call. collect_usage is the fetch, one live
#                       attempt per token, plus the haiku nudge that makes the CLI
#                       rotate a stale credential, so "refresh" here means: make
#                       sure a NETWORKED collection actually happened. A pass
#                       collected earlier with the network off (which
#                       resolve_shared_identity --auto forces) is discarded and
#                       redone rather than inherited, because the COLLECTED guard
#                       would otherwise pin cache-only rows in place for the whole
#                       run. Re-running a networked pass on top of a networked pass
#                       is deliberately NOT done: the usage API rate-limits per
#                       token at ~1/min, so a second sweep would 429 the rows that
#                       had just succeeded.
#
# R6, peer rows: a `peer` row is STALE by this test, deliberately and identically
# to a `cached` one. Both are real numbers about a real seat that this run did not
# measure, so anything that demands a live row (the strict first pass of
# switch-auto, `live:` in --json) must keep refusing both, and anything that
# accepts a cached row (resolve_mode, the burn-down hold, switch-auto's second
# pass) must accept both. Nothing gets a new exemption because it arrived by ssh.
usage_row_stale() {  # usage_row_stale <slot-index>
  local i="${1:--1}"
  [[ "$i" =~ ^[0-9]+$ ]] || return 1
  [[ "${U_STATE[$i]}" == "live" || "${U_STATE[$i]}" == "dup" ]] && return 1
  return 0
}

usage_stale_rows() {  # names of the slots still not live, comma-joined; empty when all fresh
  local i out=""
  for i in "${!DIRS[@]}"; do
    usage_row_stale "$i" || continue
    out="${out:+$out, }${U_EMAIL[$i]:-${LABELS[$i]}} (${U_WHY[$i]:-unknown})"
  done
  printf '%s' "$out"
}

ensure_fresh_usage() {
  if (( COLLECTED )) && (( ! COLLECTED_NET )) && (( NET )); then
    COLLECTED=0
    SHARED_TWIN_SLOT=-1
  fi
  collect_usage
}

# ── who does the shared ~/.claude credential belong to? ──────────────────────
# resolve_shared_identity [--fast|--auto|--verify]
#   --fast    ~/.claude.json's oauthAccount only; never touches the network.
#             Used by `status`, which the dashboard polls.
#   --auto    (default) oauthAccount for the label, ALWAYS cross-checked against
#             the free byte-identity comparison to pool copies (filesystem only,
#             no network, no `claude` subprocess), falling back to the full
#             network fingerprint only when there is no oauthAccount to trust.
#             Used by `active`, which the dashboard polls, rather than believing
#             auth status, and never skipping the free check just because
#             oauthAccount exists (that used to make --auto a no-op check in
#             normal operation, since oauthAccount is set almost always).
#   --verify  always fingerprint (network), and report any disagreement. This is the
#             only mode that ALSO consults `claude auth status`, a real third opinion
#             now that it is probed with CLAUDE_CONFIG_DIR unset (see the header block)
#            , because it is the only mode that already accepts a subprocess+network
#             cost. --fast and --auto stay subprocess-free for the dashboard's polling.
# Sets SHARED_EMAIL, SHARED_SOURCE, SHARED_WARN, SHARED_SLOT, SHARED_FP, and (in
# --verify) SHARED_AUTH + AUTH_WARN.
SHARED_EMAIL=""; SHARED_SOURCE=""; SHARED_WARN=""; SHARED_SLOT=-1; SHARED_FP=""
SHARED_AUTH=""; AUTH_WARN=""

# The third signal. auth status renders the config JSON's oauthAccount, so agreeing
# with SHARED_EMAIL is the NORMAL case and says the CLI resolves the same file we read.
# Disagreement is real and worth printing: it means the CLI resolved a DIFFERENT config
# (an inherited CLAUDE_CONFIG_DIR is the usual cause), which is precisely the class of
# bug that produced the 2026-07-30 false conclusion.
check_auth_status() {
  SHARED_AUTH=""; AUTH_WARN=""
  (( NET )) || return 0          # --no-refresh promises no subprocess, no network
  command -v claude >/dev/null 2>&1 || return 0
  SHARED_AUTH="$(shared_email)"
  [[ -n "$SHARED_AUTH" && -n "$SHARED_EMAIL" ]] || return 0
  [[ "$SHARED_AUTH" == "$SHARED_EMAIL" ]] && return 0
  # shellcheck disable=SC2088  # "~/.claude.json" is display text, not a path to expand
  AUTH_WARN="WARNING: \`claude auth status\` reports ${SHARED_AUTH}, but ~/.claude.json says ${SHARED_EMAIL}. Both were read the way a real session resolves config (CLAUDE_CONFIG_DIR unset), so they should agree, a stray CLAUDE_CONFIG_DIR in this environment, or a session rewriting ~/.claude.json mid-read, is the usual cause."
}
# shellcheck disable=SC2088  # "~/.claude.json" in the SOURCE strings below is display
#                            # text for a human to read, not a path to expand
resolve_shared_identity() {
  local mode="${1:---auto}"
  SHARED_EMAIL=""; SHARED_SOURCE=""; SHARED_WARN=""; SHARED_SLOT=-1; SHARED_FP=""
  SHARED_AUTH=""; AUTH_WARN=""
  local claim; claim="$(config_email "$HOME/.claude")"

  if [[ "$mode" == "--fast" ]]; then
    if [[ -n "$claim" ]]; then
      SHARED_EMAIL="$claim"; SHARED_SOURCE="~/.claude.json oauthAccount"
      SHARED_SLOT="$(slot_for_email "$claim")"
    fi
    return 0
  fi

  if [[ "$mode" == "--auto" ]] && [[ -n "$claim" ]]; then
    SHARED_EMAIL="$claim"; SHARED_SOURCE="~/.claude.json oauthAccount"
    SHARED_SLOT="$(slot_for_email "$claim")"
    # The byte-identity check against pool copies is free, filesystem only, no
    # network, no `claude` subprocess, so --auto (used only by `active`, which
    # the dashboard polls) always runs it, instead of trusting oauthAccount blind
    # the way the old guard did (it skipped the fingerprint entirely whenever
    # oauthAccount existed, i.e. always in normal operation, the one command
    # whose job is "which account am I on" would have silently reproduced the
    # 2026-07-30 incident if oauthAccount ever drifted from the credential
    # through any path other than switch-all). Only the network-dependent
    # CADENCE fingerprint (a live usage fetch per pool account) is skipped here,
    # to keep --auto fast.
    if command -v jq >/dev/null 2>&1; then
      local saved_net="$NET"
      NET=0
      collect_usage
      NET="$saved_net"
      if (( SHARED_TWIN_SLOT >= 0 )); then
        SHARED_FP="${U_EMAIL[$SHARED_TWIN_SLOT]}"
        local twin_note; twin_note="identical credential bytes in $(tilde "${DIRS[$SHARED_TWIN_SLOT]}")"
        if [[ "$SHARED_FP" != "$claim" ]]; then
          SHARED_SOURCE="~/.claude.json oauthAccount for the label / $twin_note for the numbers"
          SHARED_WARN="WARNING: identity sources disagree, ~/.claude.json says $claim, but $twin_note says $SHARED_FP. Trusting $claim for the label; the shared credential's bytes actually match $SHARED_FP. Reconcile with /login in one shared-dir session before switching."
        else
          SHARED_SOURCE="~/.claude.json oauthAccount, confirmed by $twin_note"
        fi
      fi
    fi
    return 0
  fi

  # fingerprint path (mode == --verify, or --auto with no oauthAccount to trust)
  if ! command -v jq >/dev/null 2>&1; then
    if [[ -n "$claim" ]]; then
      SHARED_EMAIL="$claim"
      SHARED_SOURCE="~/.claude.json oauthAccount (no jq, fingerprint skipped)"
      SHARED_SLOT="$(slot_for_email "$claim")"
    fi
    return 0
  fi
  # keep the degraded (no-oauthAccount) path inside callers' timeouts, the dashboard
  # allows this script 30s and there is one fetch per pool account
  #
  # PEER_SKIP is the same rule extended to the peer step, and it needs its own
  # switch because USAGE_CURL_TIMEOUT bounds curl and bounds nothing about ssh.
  # peer_fill lives inside collect_usage, so every caller inherits it, and this
  # branch runs with NET=1: measured 2026-08-27, `rota active` against three
  # hanging peers took 32s and blew the 30s budget the line above exists to
  # respect. It is skipped rather than squeezed because this path wants an
  # IDENTITY, not quota: which credential sits in ~/.claude is a question about
  # THIS box, and a peer's borrowed percentages cannot answer it. The dashboard
  # path (--verify, and the oauthAccount fast path) is untouched and still peers.
  if [[ "$mode" != "--verify" ]]; then
    USAGE_CURL_TIMEOUT=5
    PEER_SKIP=1
  fi
  collect_usage
  PEER_SKIP=0

  local fp="" fp_src="" ambiguous=0 i
  local n_match=0 first_match=-1 n_left=0 first_left=-1
  if (( SHARED_TWIN_SLOT >= 0 )); then
    fp="${U_EMAIL[$SHARED_TWIN_SLOT]}"
    fp_src="identical credential bytes in $(tilde "${DIRS[$SHARED_TWIN_SLOT]}")"
  elif [[ -n "$S_SDR" ]]; then
    # U_SDR/S_SDR, not U_WKR/S_WKR: the cadence match only means "same account" when
    # both sides describe the SAME window. U_WKR now follows whichever weekly limit
    # binds, which can be a per-model one on one account and the all-model one on
    # another, comparing those two would be comparing different clocks.
    for i in "${!DIRS[@]}"; do
      if [[ "${U_STATE[$i]}" == "live" && -n "${U_SDR[$i]}" ]]; then
        if [[ "${U_SDR[$i]:0:16}" == "${S_SDR:0:16}" ]]; then
          n_match=$((n_match + 1)); (( first_match < 0 )) && first_match="$i"
        fi
      elif [[ "${U_STATE[$i]}" != "dup" ]]; then
        # no live cadence for this slot → it cannot be ruled out by elimination
        n_left=$((n_left + 1)); (( first_left < 0 )) && first_left="$i"
      fi
    done
    if (( n_match == 1 )); then
      fp="${U_EMAIL[$first_match]}"; fp_src="usage fingerprint (same weekly reset minute)"
    elif (( n_match > 1 )); then
      ambiguous=1
    elif (( n_left == 1 )); then
      fp="${U_EMAIL[$first_left]}"
      fp_src="usage fingerprint by elimination (every other pool copy has a different weekly cadence)"
    fi
  fi
  SHARED_FP="$fp"

  if [[ -n "$claim" && -n "$fp" ]]; then
    SHARED_EMAIL="$claim"
    SHARED_SLOT="$(slot_for_email "$claim")"
    if [[ "$claim" == "$fp" ]]; then
      SHARED_SOURCE="~/.claude.json oauthAccount, confirmed by $fp_src"
    else
      SHARED_SOURCE="~/.claude.json oauthAccount for the label / $fp_src for the numbers"
      SHARED_WARN="WARNING: identity sources disagree, ~/.claude.json says $claim, the $fp_src says $fp. Trusting $claim for the label and $fp for whose numbers the shared credential returned. Reconcile with /login in one shared-dir session before switching."
    fi
  elif [[ -n "$fp" ]]; then
    SHARED_EMAIL="$fp"; SHARED_SOURCE="$fp_src (no oauthAccount in ~/.claude.json)"
    SHARED_SLOT="$(slot_for_email "$fp")"
  elif [[ -n "$claim" ]]; then
    SHARED_EMAIL="$claim"; SHARED_SLOT="$(slot_for_email "$claim")"
    if (( ambiguous )); then
      SHARED_SOURCE="~/.claude.json oauthAccount (ambiguous cadence, trusting ~/.claude.json)"
    elif [[ "$S_HTTP" == "429" ]]; then
      SHARED_SOURCE="~/.claude.json oauthAccount (fingerprint unavailable: usage API 429 on the shared token)"
    else
      SHARED_SOURCE="~/.claude.json oauthAccount (fingerprint inconclusive)"
    fi
  fi
  # third signal, --verify only (it is the mode that already pays for subprocesses)
  [[ "$mode" == "--verify" ]] && check_auth_status
  if [[ -n "$SHARED_AUTH" && "$SHARED_AUTH" == "$SHARED_EMAIL" && -n "$SHARED_SOURCE" ]]; then
    SHARED_SOURCE="$SHARED_SOURCE; \`claude auth status\` agrees"
  fi
  USAGE_CURL_TIMEOUT=10
}

slot_for_email() {  # slot index for an email, or -1
  local want="${1:-}" i
  [[ -n "$want" ]] || { printf '%s' -1; return 0; }
  for i in "${!DIRS[@]}"; do
    if [[ "${LABELS[$i]}" == "$want" || "$(config_email "${DIRS[$i]}")" == "$want" ]]; then
      printf '%s' "$i"; return 0
    fi
  done
  printf '%s' -1
}

# The identified account's row shows the LIVE shared credential's numbers: that
# credential IS that account, and its idle pool copy is exactly the one allowed to
# be stale. Before this, the only account actually being spent was the only row
# with no numbers at all.
#
# The overwrite is skipped ONLY when the claimed slot's own credential is the
# byte-identical shared file (SHARED_TWIN_SLOT), then its live numbers already
# ARE the shared credential's numbers, nothing to adopt. Every other case forces
# the overwrite, including when the slot's OWN state is already "live": a bare
# "state != live" guard let the claimed slot's own pool credential, a
# different, still-valid account, silently stand in for the shared
# credential's numbers whenever identity sources disagreed (oauthAccount claims
# A, the usage fingerprint says B, and A's own pool copy happens to still be
# live). Proven 2026-07-30: shared credential at 8% weekly, oauthAccount
# claiming CS, CS's own pool copy live at 70%, `usage --json` reported the
# active row as 70%. The WARNING printed correctly; the numbers under it, and
# the recommendation built on them, did not.
adopt_shared_numbers() {
  (( SHARED_SLOT >= 0 )) || return 0
  [[ -n "$S_JSON" ]] || return 0
  if [[ -z "$SHARED_WARN" ]] && (( SHARED_SLOT == SHARED_TWIN_SLOT )); then
    return 0
  fi
  U_WKU[SHARED_SLOT]="$S_WKU"; U_WKR[SHARED_SLOT]="$S_WKR"
  U_SEU[SHARED_SLOT]="$S_SEU"; U_SER[SHARED_SLOT]="$S_SER"
  # the binding limit's identity travels with its number, or the row would annotate the
  # shared credential's scoped figure with the slot's own (now discarded) provenance
  U_WKK[SHARED_SLOT]="$S_WKK"; U_WKS[SHARED_SLOT]="$S_WKS"; U_SDR[SHARED_SLOT]="$S_SDR"
  U_WKX[SHARED_SLOT]=0; U_SEX[SHARED_SLOT]=0
  U_STATE[SHARED_SLOT]="live"
  # a LIVE local fetch outranks anything borrowed, so a peer row for this slot is
  # replaced outright, provenance and age included, not merely overwritten
  U_SRC[SHARED_SLOT]=""; U_AGE[SHARED_SLOT]=""; U_MEAS[SHARED_SLOT]="$RUN_MEASURED_AT"
  # the adopted numbers are this row's weekly numbers now, so its projection is
  # recomputed from them (and cleared when they carry a real reset). Before the
  # cache_put below, for the reason project_weekly's call in collect_usage gives.
  project_weekly "$SHARED_SLOT"
  if [[ -n "$SHARED_WARN" ]]; then
    U_VIA[SHARED_SLOT]="numbers from the LIVE shared ~/.claude credential, identity sources disagree (see the WARNING above); this row is what the shared credential itself reports, NOT ${U_EMAIL[$SHARED_SLOT]}'s own pool numbers"
  else
    U_VIA[SHARED_SLOT]="numbers from the LIVE shared ~/.claude credential (this account's pool copy is stale)"
  fi
  cache_put "${U_EMAIL[$SHARED_SLOT]}" "$S_WKU" "$S_WKR" "$S_SEU" "$S_SER"
  cache_flush
}

# Copy the LIVE shared credential back into its owner's pool dir. Only ever
# shared → pool, only when the shared file is NEWER (so a fresher pool copy is never
# overwritten by a staler shared one, the same direction-of-freshness rule
# switch-all's same-account force-sync already uses), and, since 2026-08-07, only
# when the shared file is not a HUSK.
#
# THIS IS THE WRITE THAT GUTTED SEAT A AND THE PERSONAL SEAT. Freshness was the only gate, and a
# mid-rotation shared credential is by definition the newest file in the pair, so
# every `rota usage` run stood ready to copy it over a complete pool copy. See
# cred_is_complete's header for the full incident.
# v2: shared slot is credential-free, there is no live shared credential, so
# every call site is short-circuited and this is a no-op by its own first
# guard ([[ -f "$shared" ]]). Kept in place; removal is riskier than disuse.
sync_live_credential_back() {  # sync_live_credential_back <slot-index>
  local i="${1:--1}"
  [[ "$i" =~ ^[0-9]+$ ]] || return 0
  local shared="$HOME/.claude/.credentials.json" dir="${DIRS[$i]}" pool="${DIRS[$i]}/.credentials.json"
  [[ -f "$shared" && -d "$dir" ]] || return 0
  [[ "$shared" -ef "$pool" ]] && return 0
  cmp -s "$shared" "$pool" && return 0
  # content before freshness: a newer file is not a better file
  cred_overwrite_refused "$shared" "$pool" "the pool credential for ${LABELS[$i]}" && return 0
  if [[ -f "$pool" && ! "$shared" -nt "$pool" ]]; then
    # "-nt" said shared is NOT newer than pool, which is also true on a tie
    # (same mtime second), say which one it actually is, not just "NEWER".
    if [[ "$pool" -nt "$shared" ]]; then
      printf 'note: %s pool copy is NEWER than the live shared credential, left alone\n' "$(tilde "$dir")" >&2
    else
      printf 'note: %s pool copy is the SAME AGE as the live shared credential (mtimes tie), left alone\n' "$(tilde "$dir")" >&2
    fi
    return 0
  fi
  # atomic: temp file in the SAME dir (same filesystem, so mv is a rename), so a
  # reader mid-write never sees truncated JSON, the same discipline
  # move_oauth_account already uses for ~/.claude.json.
  local tmp="$pool.failover-tmp.$$"
  if cp -p "$shared" "$tmp" 2>/dev/null && mv "$tmp" "$pool" 2>/dev/null; then
    chmod 600 "$pool" 2>/dev/null || true
    printf 'synced live credential back into %s (single-use refresh tokens had rotted the pool copy)\n' "$(tilde "$dir")" >&2
  else
    rm -f "$tmp" 2>/dev/null || true
    printf 'note: could not sync the live credential into %s\n' "$(tilde "$dir")" >&2
  fi
}

# ── recommendation ───────────────────────────────────────────────────────────
# Use-it-or-lose-it: prefer the SOONEST weekly reset, so headroom about to expire
# gets spent first, but only among accounts that clear the health floor, since
# switching onto an account with 8% left just walls again in an hour. Cached
# numbers never feed the pick. Every excluded row gets a reason.
#
# "weekly" throughout here is the BINDING weekly limit (U_WKU/U_WKR, see
# weekly_binding), not seven_day: the floor and the ranking have to be judged against
# the cap that will actually wall the account, or the pick is made on a number that
# stops being true first.
#
# RANKING, in full (the FRESH tier added 2026-07-30):
#   1. eligible + has a real weekly reset → ranked by that reset, soonest first.
#   2. eligible + FRESH (no active window) → ranked BEHIND every account in tier 1,
#      because an unstarted window has nothing expiring, so there is no urgency to
#      spend it. Ties inside the tier go to accounts-file order, which is already
#      the operator's preferred order.
#   3. FRESH still WINS whenever tier 1 is empty, no healthy account has an active
#      window, or the fresh account is the only one clearing the floor. It must never
#      be excluded: 100% remaining is the most headroom on offer.
#
# THE THIRD ARGUMENT, allow_cached (added 2026-08-06), defaults to 0, which is
# exactly the behaviour above, and what the dashboard keeps using. Only switch-auto
# passes 1, and only as a SECOND pass after the strict live-only pass found nothing:
# a switch that dead-ends is worse than a switch decided on age-marked numbers, since
# dead-ending is precisely what forces the operator to name an account by hand. Even then a
# cached row must still be complete and UNEXPIRED to be scored, a window that has
# already reset has a number measured inside a window that no longer exists, so it is
# not "old data", it is wrong data. REC_CACHED reports which pass produced the pick.
#
# ALL OF THE ABOVE IS *FLOOR* MODE, and it is the default. Under scarcity the pick is
# preceded by a burn-down HOLD, see resolve_mode() and active_burndown_hold() below.
#
# ── which mode is in force (2026-08-06) ──────────────────────────────────────
# The scarcity test is deliberately about the POOL, not about the active account: how
# good is the best place we could go? Leaving 12% unspent behind is cheap when a fresh
# account is waiting for you, and expensive when every plan is nearly maxed, which is
# exactly the situation that prompted this (personal 0% left, work 31%, team 12%).
#
# "Best" is the highest weekly-left among the OTHER accounts with usable, unexpired
# numbers. Weekly only: the 5h window turns over several times a day, so it says
# nothing about whether there is somewhere to go for the rest of the week. No other
# account with usable numbers at all also counts as scarcity, there is nowhere
# comfortable to go by definition.
REC_MODE="floor"; REC_MODE_FORCED=0; BEST_ALT_EMAIL=""; BEST_ALT_PCT=""
resolve_mode() {
  REC_MODE="floor"; REC_MODE_FORCED=0; BEST_ALT_EMAIL=""; BEST_ALT_PCT=""
  local i left
  for i in "${!DIRS[@]}"; do
    # `peer` counts exactly as `cached` does here, and everywhere else a state is
    # tested: it is real data about a real seat, measured somewhere else. Letting
    # it in where cached is in (and, more importantly, keeping it out where cached
    # is out) is the whole rule, see the R6 note above usage_row_stale.
    [[ "${U_STATE[$i]}" == "live" || "${U_STATE[$i]}" == "cached" || "${U_STATE[$i]}" == "peer" ]] || continue
    (( SHARED_SLOT >= 0 )) && (( i == SHARED_SLOT )) && continue
    (( U_WKX[i] == 0 )) || continue
    left="$(remaining "${U_WKU[$i]}")"
    [[ -n "$left" ]] || continue
    if [[ -z "$BEST_ALT_PCT" ]] || (( left > BEST_ALT_PCT )); then
      BEST_ALT_PCT="$left"; BEST_ALT_EMAIL="${U_EMAIL[$i]}"
    fi
  done
  if [[ -z "$BEST_ALT_PCT" ]] || (( BEST_ALT_PCT < COMFORTABLE_PCT )); then
    REC_MODE="burn-down"
  fi
  case "${CLAUDE_FAILOVER_MODE:-auto}" in
    auto|'')             ;;
    floor)               REC_MODE="floor";     REC_MODE_FORCED=1 ;;
    burn-down|burndown)  REC_MODE="burn-down"; REC_MODE_FORCED=1 ;;
    *) die "CLAUDE_FAILOVER_MODE must be auto, floor or burn-down (got '${CLAUDE_FAILOVER_MODE}')" ;;
  esac
}

# ── burn it down before you switch (SCARCITY mode only) ──────────────────────
# In burn-down mode the operator spends an account to ~0 and only then moves: "let's stay on
# the current account until we get to 98, 99, almost 100% (ideally 100%), and then
# switch to the CS account". The health floor is the wrong tool for that call and does
# the exact opposite, at 9% weekly left the active account is UNDER the 20% floor, so
# every run tells him to switch off headroom he still wants to spend, with nowhere
# better to spend it.
#
# While this mode is in force the floor keeps exactly ONE job: deciding what we may
# move ONTO. What we move OFF is decided here, by a single exhaustion threshold: the
# active account is HELD until its weekly window is at or under EXHAUSTED_PCT % left
# (default 2 → ~98%+ used). Nothing about the floor itself changes; it simply stops
# being consulted about the account we are already spending.
#
# ONE exception, the 5h session window. Weekly headroom you cannot reach is not
# headroom: when the 5h window is spent, Claude is blocked RIGHT NOW and a switch is
# the only thing that unblocks it. That case does NOT hold, it falls through to the
# normal ranking, and recommendation_text names the window that caused it.
#
# CACHED numbers may hold, unlike the pick above, and the asymmetry is deliberate:
# moving ONTO an account on stale numbers can strand him on a dead one, whereas
# staying put changes nothing he was not already doing. The age still rides along
# (REC_CACHED / BURN_CACHED), so a cached decision stays labelled as such. An
# EXPIRED weekly number is still never used, it was measured inside a window that
# no longer exists. An expired 5h window is the opposite: it has already reset, so
# it cannot be the thing blocking him.
BURN_WKL=""; BURN_SEL=""; BURN_CACHED=0; BURN_BLOCKED=0
active_burndown_hold() {   # 0 = hold the active account, 1 = let the ranking decide
  BURN_WKL=""; BURN_SEL=""; BURN_CACHED=0; BURN_BLOCKED=0
  (( SHARED_SLOT >= 0 )) || return 1
  case "${U_STATE[$SHARED_SLOT]}" in
    live)        ;;
    cached|peer) BURN_CACHED=1 ;;   # borrowed or remembered, either way not this run's
    *)           return 1 ;;        # dup / no data, nothing to hold on
  esac
  (( U_WKX[SHARED_SLOT] == 0 )) || return 1
  BURN_WKL="$(remaining "${U_WKU[$SHARED_SLOT]}")"
  [[ -n "$BURN_WKL" ]] || return 1
  # weekly spent → the burn-down is finished, hand the decision back to the ranking
  (( BURN_WKL > EXHAUSTED_PCT )) || return 1
  (( U_SEX[SHARED_SLOT] == 0 )) && BURN_SEL="$(remaining "${U_SEU[$SHARED_SLOT]}")"
  if [[ -n "$BURN_SEL" ]] && (( BURN_SEL <= EXHAUSTED_PCT )); then
    BURN_BLOCKED=1; return 1
  fi
  return 0
}

# REC_HOLD says the pick is a burn-down HOLD rather than something the ranking chose,
# and REC_NEXT_* remember what the ranking WOULD have picked, so the stay sentence can
# still tell him where `rota switch` goes once the account is spent.
#
# NB a SECOND picker exists (stage-2 review, 2026-08-12): the pool keeper's
# auto-switch (rota-keeper.sh, step 4), the 90%-wall safety valve, on its
# own knobs (AUTO_SWITCH_PCT, AUTO_SWITCH_TARGET_MAX_PCT,
# AUTO_SWITCH_TARGET_MIN_LEFT_PCT, AUTO_SWITCH_BOUNCE_SECS).
#
# 2026-08-16, CÉDRIC DECIDED, and the two are now ALIGNED ON THE RANKING:
# "always work on the one that expires next and burn all those tokens before
# switching to the one right after", here and in the keeper. That the keeper used
# to rank by lowest utilization is history; the match is deliberate, not
# accidental drift, so do not "restore" the difference.
#
# ⚠️ AND SINCE 2026-08-28 THE ALIGNMENT IS NOT A CONVENTION ANY MORE, IT IS ONE
# FUNCTION. Both pickers call rota_seat_deadline + rota_deadline_beats
# (rota-ranking.sh). Convention was not enough: this picker moved to
# min(weekly reset, SEAT END) on 2026-08-27 and the keeper did not, so for a
# cancelled seat whose end date falls before its next reset the two named
# DIFFERENT seats - live on the pool within days. Do not re-inline the
# comparison here to "make this file self-contained"; that is precisely how the
# two copies drifted, and do NOT close a future gap by reverting the deadline to
# the weekly reset alone.
#
# What remains deliberately DIFFERENT is the ELIGIBILITY floors: this picker's
# MIN_WEEKLY (20%-left) + MIN_SESSION (10%-left) serve an interactive choice the
# operator is watching, while the keeper adds its own 30%-left floor and 80%
# ceiling because it fires unattended. Those decide WHICH seats may be picked,
# not in what ORDER, so they stay per-caller. A change to either side's floor
# should still be weighed against the other.
#
# REC_BEST_USED is the incumbent's weekly USED %, carried only so the tie-break
# (rule 3 in rota_deadline_beats) has something to compare against; it is never
# printed.
#
# REC_PROJECTED says whether the instant in REC_RESET was MEASURED or inferred
# from the seat's cadence (project_weekly). Every surface that prints it marks it
# `~`, so a deadline this box worked out for itself can never be read as
# something the vendor reported.
REC_SLOT=-1; REC_EMAIL=""; REC_RESET=""; REC_FRESH=0; REC_CACHED=0
REC_BEST_USED=""; REC_DEADLINE_KIND=""; REC_PROJECTED=0
REC_HOLD=0; REC_NEXT_EMAIL=""; REC_NEXT_ALIAS=""
compute_recommendation() {  # compute_recommendation <exclude_active 0|1> <require_pool_dir 0|1> [allow_cached 0|1]
  local excl_active="${1:-0}" need_pool="${2:-0}" allow_cached="${3:-0}" i wkl sel cached_row
  REC_SLOT=-1; REC_EMAIL=""; REC_RESET=""; REC_FRESH=0; REC_CACHED=0
  REC_BEST_USED=""; REC_DEADLINE_KIND=""; REC_PROJECTED=0
  REC_HOLD=0; REC_NEXT_EMAIL=""; REC_NEXT_ALIAS=""
  BURN_WKL=""; BURN_SEL=""; BURN_CACHED=0; BURN_BLOCKED=0
  resolve_mode
  U_REC=(); U_REASON=()
  for i in "${!DIRS[@]}"; do
    U_REC[i]=0; U_REASON[i]=""; cached_row=0
    if [[ "${U_STATE[$i]}" == "dup" ]]; then
      U_REASON[i]="same account as an earlier row"; continue
    fi
    if (( need_pool )) && [[ "${DIRS[$i]}" -ef "$HOME/.claude" ]]; then
      U_REASON[i]="its home IS the shared ~/.claude, nothing to swap in"; continue
    fi
    if [[ "${U_STATE[$i]}" != "live" ]]; then
      # `peer` rides with `cached`, in BOTH directions: it is admitted only on the
      # second (allow_cached) pass switch-auto makes, and the strict live-only
      # first pass excludes it exactly as it excludes a cached row. A peer number
      # is real, but it was not measured here this run, and that is the property
      # the strict pass is testing.
      if (( allow_cached )) && [[ "${U_STATE[$i]}" == "cached" || "${U_STATE[$i]}" == "peer" ]] \
         && (( U_WKX[i] == 0 )) && (( U_SEX[i] == 0 )); then
        cached_row=1
      else
        U_REASON[i]="no LIVE numbers (${U_WHY[$i]:-unknown}), cached numbers never feed the pick"; continue
      fi
    fi
    wkl="$(remaining "${U_WKU[$i]}")"; sel="$(remaining "${U_SEU[$i]}")"
    # "incomplete" is now strictly about the NUMBERS. A missing resets_at no longer
    # counts: that is the FRESH window described above (100% left, nothing expiring),
    # and treating it as incomplete excluded the healthiest account there was.
    if [[ -z "$wkl" || -z "$sel" ]]; then
      U_REASON[i]="incomplete usage data"; continue
    fi
    # used-first, same order as the rows and the statusline
    if (( wkl < MIN_WEEKLY )); then
      U_REASON[i]="weekly $(used "${U_WKU[$i]}")% used · ${wkl}% left$(scope_note "${U_WKS[$i]}") is under the ${MIN_WEEKLY}%-left floor"; continue
    fi
    if (( sel < MIN_SESSION )); then
      U_REASON[i]="5h $(used "${U_SEU[$i]}")% used · ${sel}% left is under the ${MIN_SESSION}%-left floor"; continue
    fi
    if (( excl_active )) && [[ -n "$SHARED_EMAIL" && "${U_EMAIL[$i]}" == "$SHARED_EMAIL" ]]; then
      U_REASON[i]="already the active account"; continue
    fi
    U_REC[i]=1
    # ⚠️ THE DEADLINE IS min(weekly reset, SEAT END), NOT THE WEEKLY RESET ALONE,
    # and the comparison is rota_deadline_beats, NOT an inline `<`. Both live in
    # rota-ranking.sh so rota-keeper.sh's unattended picker orders the pool the
    # same way this one does. The three rules it encodes, all of which used to be
    # written out here: a real deadline always outranks an account with nothing
    # expiring; then soonest wins; then an exact tie goes to the lowest weekly
    # utilization, so the pick never falls back on accounts-file order.
    local dl_pair deadline dl_kind used_pct
    dl_pair="$(seat_deadline "$i")"
    deadline="${dl_pair%%$'\t'*}"; dl_kind="${dl_pair#*$'\t'}"
    used_pct="$(used "${U_WKU[$i]}")"
    if (( REC_SLOT < 0 )) \
       || rota_deadline_beats "$deadline" "$used_pct" "$REC_RESET" "$REC_BEST_USED"; then
      REC_SLOT="$i"; REC_RESET="$deadline"; REC_EMAIL="${U_EMAIL[$i]}"
      REC_BEST_USED="$used_pct"; REC_DEADLINE_KIND="$dl_kind"
      # ⚠️ FRESH IS A FACT ABOUT THE WINDOW, NOT ABOUT THE DEADLINE. It used to be
      # "this row has no deadline at all" (the empty-string sentinel), which was
      # the same thing right up until a PROJECTED reset gave an untouched window a
      # deadline. Then the pick published weekly_fresh:false while its own
      # accounts[].weekly.fresh stayed true - two published fields disagreeing
      # about one window - and the honest "its weekly window has not started yet"
      # sentence vanished exactly when it was still true. So it is window_fresh,
      # the same predicate the row itself publishes, and the two cannot diverge.
      REC_FRESH=0
      window_fresh "${U_WKU[$i]}" "${U_WKR[$i]}" "${U_WKX[$i]}" && REC_FRESH=1
      # Was the instant that ORDERED this pick measured or inferred? Only when the
      # weekly reset bound it: a seat-end deadline is a date out of billing.json,
      # which is nobody's projection.
      REC_PROJECTED=0
      [[ "$dl_kind" == "reset" && -z "${U_WKR[$i]}" && -n "${U_WKP[$i]:-}" ]] && REC_PROJECTED=1
      REC_CACHED="$cached_row"
    fi
  done
  # The burn-down override, SCARCITY MODE ONLY, and applied AFTER the loop on
  # purpose: every row keeps the exclusion reason it earned, and the ranking's answer
  # survives in REC_NEXT_* so the stay sentence can name where he goes next. Only ever
  # overrides a pick that would move him OFF the active account, a ranking that
  # already says "stay" is left with its own (correct, unchanged) wording.
  if [[ "$REC_MODE" == "burn-down" ]] \
     && (( SHARED_SLOT >= 0 )) && (( REC_SLOT != SHARED_SLOT )) && active_burndown_hold; then
    if (( REC_SLOT >= 0 )); then
      REC_NEXT_EMAIL="${U_EMAIL[$REC_SLOT]}"; REC_NEXT_ALIAS="$(basename "${DIRS[$REC_SLOT]}")"
    fi
    REC_HOLD=1
    REC_SLOT="$SHARED_SLOT"; REC_EMAIL="${U_EMAIL[$SHARED_SLOT]}"
    REC_RESET="${U_WKR[$SHARED_SLOT]}"
    # A HOLD races the instant this window dies, and a projected one is still that
    # instant: "nothing is expiring" was the sentence a known cadence disproves.
    REC_PROJECTED=0
    if [[ -z "$REC_RESET" && -n "${U_WKP[$SHARED_SLOT]:-}" ]]; then
      REC_RESET="${U_WKP[$SHARED_SLOT]}"; REC_PROJECTED=1
    fi
    # window_fresh, not "REC_RESET is empty", for the reason spelled out above:
    # the projection gives this window a deadline without making it any less
    # unstarted, and this field has to agree with the row's own `weekly.fresh`.
    REC_FRESH=0
    window_fresh "${U_WKU[$SHARED_SLOT]}" "${U_WKR[$SHARED_SLOT]}" "${U_WKX[$SHARED_SLOT]}" && REC_FRESH=1
    # A HOLD is not a deadline pick: the hold sentence names the WEEKLY window it
    # is spending down, so the kind is stated rather than left over from whatever
    # the ranking had chosen before the override.
    REC_DEADLINE_KIND="reset"; [[ -n "$REC_RESET" ]] || REC_DEADLINE_KIND=""
    REC_CACHED="$BURN_CACHED"
    # the row we now recommend must not also print "skipped … under the 20%-left floor"
    U_REC[SHARED_SLOT]=1; U_REASON[SHARED_SLOT]=""
  fi
}

launch() {           # launch <index> [extra claude args...]
  local i="$1"; shift || true
  local dir="${DIRS[$i]}" label="${LABELS[$i]}"
  set_index "$i"
  printf '→ Claude on account [%d/%d] %s  (%s)\n' "$((i+1))" "${#DIRS[@]}" "$label" "$dir" >&2
  # A pool dir is passed through as-is. The SHARED dir is the exception and must be
  # launched with CLAUDE_CONFIG_DIR UNSET, not set to $HOME/.claude: the CLI resolves
  # $CLAUDE_CONFIG_DIR/.claude.json, so setting it would give the session the nested
  # ~/.claude/.claude.json instead of the ~/.claude.json every other plain `claude`
  # session uses, the same wrong-file trap the header block describes, but pointed at
  # a real interactive session instead of a probe. config_json() already encodes this
  # rule for reads; this is the same rule for launches.
  if [[ "$dir" == "$HOME/.claude" ]] || { [[ -d "$dir" ]] && [[ "$dir" -ef "$HOME/.claude" ]]; }; then
    exec env -u CLAUDE_CONFIG_DIR claude "$@"
  fi
  CLAUDE_CONFIG_DIR="$dir" exec claude "$@"
}

# ── switch-all's pointer half ────────────────────────────────────────────────
# ~/.claude.json's oauthAccount is what every new session, /status and
# ccstatusline SHOW, and, under pool v2, the POINTER the shim resolves at
# every launch. Copy the target's WHOLE oauthAccount object, never hand-build
# fields, they have to stay internally consistent (accountUuid,
# organizationUuid, org name, seat/rate tiers all belong to that account's
# real login).
#
# v1 soft-failed every branch here ("this never fails the swap, the
# credential is what bills, this is only the display half"). Under v2 that
# rationale is INVERTED (stage-2 review, 2026-08-12): there is no credential
# swap any more, the pointer IS the switch, so a pointer that cannot be
# written is a switch that did not happen, and it must DIE before switch-all's
# deletion step ever runs (a deleted shared credential after a failed pointer
# write would be a mutation with no switch behind it).
move_oauth_account() {  # move_oauth_account <target-config-dir> <target-label>
  local tdir="$1" tlabel="$2"
  local tgt_cfg mine tmp shown
  tgt_cfg="$(config_json "$tdir")"; mine="$HOME/.claude.json"
  if ! command -v jq >/dev/null 2>&1; then
    die "cannot move the active-account pointer: jq is missing (brew install jq). Nothing was changed, the pointer IS the switch under pool v2, so there is no partial fallback."
  fi
  if [[ ! -f "$tgt_cfg" ]] || [[ -z "$(jq -r '.oauthAccount.emailAddress // empty' "$tgt_cfg" 2>/dev/null || true)" ]]; then
    die "cannot switch to $tlabel: $(tilde "$tgt_cfg") has no oauthAccount to copy, that dir has never completed a login. Log it in once (rota login $tlabel, then /login), then re-run. Nothing was changed."
  fi
  if [[ ! -f "$mine" ]]; then
    # A fresh machine has no ~/.claude.json until the first bare `claude` run.
    # The pointer IS the switch, so create the file with nothing but the claim;
    # Claude Code fills in the rest on its next launch (it holds no secret: the
    # credential lives in the seat dir, so the CLI's own 644 is fine).
    if ! printf '{}\n' > "$mine"; then
      die "cannot switch: ~/.claude.json does not exist and could not be created. Nothing was changed."
    fi
    printf 'created ~/.claude.json (it did not exist yet: fresh machine) to hold the active-seat pointer\n' >&2
  fi
  # atomic: temp file in the SAME dir, then mv
  tmp="$mine.failover-tmp.$$"
  if jq --argjson oa "$(jq -c '.oauthAccount' "$tgt_cfg")" '.oauthAccount = $oa' "$mine" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$mine"
  else
    rm -f "$tmp"
    die "could not rewrite ~/.claude.json's oauthAccount (jq failed, is the file valid JSON?). Nothing was changed; the switch did not happen."
  fi
  # ~/.claude.json is rewritten constantly by running sessions, so this write can
  # simply lose the race, re-read and say so rather than assuming it stuck.
  shown="$(jq -r '.oauthAccount.emailAddress // empty' "$mine" 2>/dev/null || true)"
  if [[ "$shown" == "$tlabel" ]]; then
    printf 'displayed identity (~/.claude.json oauthAccount) now %s\n' "$tlabel" >&2
  else
    printf 'WARNING: wrote oauthAccount=%s but ~/.claude.json now reads %s, a running session rewrote it. The CREDENTIAL swap (what bills) stands; re-run switch-all or /login in one session to fix the display.\n' "$tlabel" "${shown:-unknown}" >&2
  fi
}

# ── the usage dashboard ──────────────────────────────────────────────────────
# THE QUESTION THIS ANSWERS, in the first five lines: which account am I on,
# which can I switch to RIGHT NOW, and which are dead until when. The operator,
# 2026-08-07: "usually I will run it to see which accounts have open capacity at
# the moment… if I can just quickly see which account to switch to, which ones
# are active, and which other ones are alternatives."
#
# So the report is THREE BUCKETS, ACTIVE, ALTERNATIVES, UNAVAILABLE, and the
# recommendation comes LAST, where it reads as the conclusion of the picture
# above it rather than as a claim you have to go and verify.
#
# Bucket membership is NOT re-derived here. ALTERNATIVES is exactly the
# optimizer's own U_REC predicate (compute_recommendation), minus the active
# row; UNAVAILABLE is everything else. If the two ever disagreed, the table
# would be advertising a switch the optimizer refuses to make.
#
# Nothing is deleted, only relocated: slot paths, the identity/fingerprint line,
# the full `skipped …` sentences and the note/why lines all still print, under
# --verbose. The default view is the scannable one.

# live | cached <stamp> | duplicate row | no data, the per-account provenance
# marker, kept on EVERY row (not just the active one) because "is this number
# from this minute or from last Tuesday" changes what you do with it.
state_tag() {  # state_tag <slot-index>
  case "${U_STATE[$1]}" in
    live)   printf 'live' ;;
    cached)
      # fetched_at age, on every cached row (pool v2). Older than 60 min the
      # row is not "cached", it is STALE, say so with the age up front, so a
      # last-Tuesday number can never be read as a current one.
      local te="${U_AGE[$1]:-}" now age
      if [[ "$te" =~ ^[0-9]+$ ]]; then
        now="$(date '+%s')"; age=$(( now - te ))
        if (( age > 3600 )); then
          printf 'stale %dh' "$(( age / 3600 ))"
          return 0
        fi
      fi
      printf 'cached %s' "${U_TS[$1]}" ;;
    peer)
      # WHOSE MEASUREMENT IS THIS. A number this box did not take must say so, and
      # say how old it is once that stops being "just now": the peer answers from
      # its own cache, which for a seat nothing runs sessions on can be days old.
      # age_short answers "" for anything young enough to be current.
      local pa; pa="$(age_short "${U_AGE[$1]:-}")"
      if [[ -n "$pa" ]]; then printf 'via %s, %s old' "${U_SRC[$1]:-a peer}" "$pa"
      else printf 'via %s' "${U_SRC[$1]:-a peer}"; fi ;;
    dup)    printf 'duplicate row' ;;
    *)      printf 'no data' ;;
  esac
}

# The ACTIVE account's two window rows: meter, both polarities, countdown.
#
# POLARITY (revised 2026-08-07): the row now leads with "% LEFT" because it is
# now drawn next to a meter whose filled cells ARE the left figure, a row that
# said "11% used" beside an 89%-full bar would make you read the bar backwards.
# The "% used" number the Claude Code statusline reports is still right there,
# labelled, one field along; and every SENTENCE in the report (the exclusion
# reasons, the recommendation, the mode line) still leads with used, unchanged.
# So both readings remain available, which is what the 2026-07-30 incident
# actually needs, see the note above remaining().
render_active_window() {  # render_active_window <name> <util> <reset-iso> <expired 0|1> [scope] [projected-iso]
  local name="$1" util="${2:-}" iso="${3:-}" exp="${4:-0}" scope="${5:-}" proj="${6:-}"
  local left spent col metrics when secs
  left="$(remaining "$util")"; spent="$(used "$util")"
  if (( exp )); then
    printf '    %-7s %s   %s\n' "$name" "$(paint "$CLR_DIM" "$(usage_bar '')")" \
      "$(paint "$CLR_DIM" 'expired (window reset since)')"
    return 0
  fi
  if [[ -z "$left" ]]; then
    printf '    %-7s %s   %s\n' "$name" "$(paint "$CLR_DIM" "$(usage_bar '')")" \
      "$(paint "$CLR_DIM" 'no data')"
    return 0
  fi
  col="$(pct_color "$left")"
  # padded to the widest shape this pair can take ("  0% left · 100% used"), so
  # the reset column lines up whatever the numbers are
  metrics="$(printf '%3s%% left · %s%% used' "$left" "$spent")"
  when='no active window yet (starts on first use)'
  if [[ -n "$iso" ]]; then
    secs="$(iso_in_seconds "$iso")"
    if [[ -n "$secs" ]]; then when="resets $(human_delta "$secs")"; else when="$(reset_phrase "$iso")"; fi
  elif [[ -n "$proj" ]]; then
    # ⚠️ ONE TILDE IS THE WHOLE DISCLOSURE, so it is never dropped: this instant
    # was computed from the seat's cadence (project_weekly), not reported by the
    # vendor, and the legend under the table says so once. "no active window yet"
    # is still the honest phrase when there is nothing to project from; what it
    # was NOT honest about was a seat whose next reset this box could name.
    secs="$(iso_in_seconds "$proj")"
    if [[ -n "$secs" ]]; then when="resets ~$(human_delta "$secs")"
    else when="resets ~$(fmt_reset "$proj")"; fi
  fi
  printf '    %-7s %s   %s%s   %s\n' \
    "$name" "$(paint "$col" "$(usage_bar "$left")")" \
    "$(paint "$col" "$(printf '%-21s' "$metrics")")" \
    "$(scope_note "$scope")" \
    "$(paint "$CLR_DIM" "$when")"
}

# One ALTERNATIVES line: both windows in the polarity that decides, then the
# EXACT command to take it. The command is the point, an alternative you have
# to go and look up the alias for is not one you can act on at a glance.
render_alt_row() {  # render_alt_row <slot-index> <email-width>
  local i="$1" ew="$2" wkl sel metrics
  wkl="$(remaining "${U_WKU[$i]}")"; sel="$(remaining "${U_SEU[$i]}")"
  metrics="$(printf 'weekly %3s%% left · 5h %3s%% left' "$wkl" "$sel")"
  printf '  %s %s  %s  %s  %s\n' \
    "$(paint "$CLR_GREEN" '✓')" \
    "$(printf '%-*s' "$ew" "${U_EMAIL[$i]}")" \
    "$(paint "$(pct_color "$wkl")" "$metrics")" \
    "$(paint "$CLR_BOLD" "$(printf '%-22s' "rota switch $(basename "${DIRS[$i]}")")")" \
    "$(paint "$CLR_DIM" "[$(state_tag "$i")]")"
}

# One UNMEASURED line: what is not known, the DEADLINE that actually matters,
# and the exact command that would answer it.
#
# ⚠️ THE END DATE IS THE COLUMN THAT CHANGES BEHAVIOUR. For a cancelled seat the
# question is never "is this account any good", it is "how many weekly windows
# does it have left, ever". Naming the date turns a row that read as an obituary
# into a deadline, which is what it always was.
#
# The reason column is 23 wide (short_reason's one 23-char arm lands here) and
# the note column 33 (the width of "cancelled, quota until <ISO date>"), so
# every row in this bucket puts its command in the same place.
render_unmeasured_row() {  # render_unmeasured_row <slot-index> <email-width>
  local i="$1" ew="$2" ends note alias
  ends="$(seat_ends_on "$i")"
  alias="$(basename "${DIRS[$i]}")"
  if seat_cancelled "$i" && [[ -n "$ends" ]]; then
    note="cancelled, quota until $ends"
  else
    note="not measured this run"
  fi
  # PAD FIRST, PAINT SECOND, the same order render_alt_row uses: an escape
  # sequence counts as characters inside a printf field width, so colouring a
  # cell before padding it shreds every column to its right.
  printf '  %s %s\n' "$(paint "$CLR_YELLOW" '?')" \
    "$(printf '%-*s  %-23s  %s  %s' \
        "$ew" "${U_EMAIL[$i]}" "$(short_reason "$i")" \
        "$(paint "$CLR_BOLD" "$(printf '%-33s' "$note")")" \
        "$(paint "$CLR_DIM" "[$(state_tag "$i")]  rota usage --record $alias <weekly-used-%>")")"
}

# One UNAVAILABLE line: a SHORT reason and when it comes back. The long
# `skipped …` sentence is not lost, it moved to --verbose.
render_unavail_row() {  # render_unavail_row <slot-index> <email-width>
  local i="$1" ew="$2" back back_txt=""
  back="$(comeback_iso "$i")"
  [[ -n "$back" ]] && back_txt="back $(when_short "$back")"
  printf '  %s %s\n' "$(paint "$CLR_RED" '✗')" \
    "$(paint "$CLR_DIM" "$(printf '%-*s  %-22s  %-22s  [%s]' \
        "$ew" "${U_EMAIL[$i]}" "$(short_reason "$i")" "$back_txt" "$(state_tag "$i")")")"
}

# The long exclusion sentence, compressed to a COLUMN. Derived from the reason
# compute_recommendation already assigned (and, for the not-live cases, from the
# U_WHY behind it) rather than re-judged here, so the short form can never say
# something the full sentence under --verbose contradicts.
scope_short() { [[ -n "${1:-}" ]] && printf ' (%s)' "$1"; return 0; }
short_reason() {  # short_reason <slot-index>
  # two `local` statements, not one: an index assigned in the SAME `local` is not
  # reliably visible to a later subscript in that statement (shellcheck SC2318)
  local i="$1"
  local r="${U_REASON[$i]}" why="${U_WHY[$i]}" wkl sel
  if [[ "${U_STATE[$i]}" == "dup" ]]; then
    printf 'duplicate of %s' "${LABELS[${U_DUP[$i]}]}"; return 0
  fi
  wkl="$(remaining "${U_WKU[$i]}")"; sel="$(remaining "${U_SEU[$i]}")"
  case "$r" in
    weekly*)
      if [[ "$wkl" == "0" ]]; then printf 'weekly spent%s' "$(scope_short "${U_WKS[$i]}")"
      else printf 'weekly %s%% left%s' "$wkl" "$(scope_short "${U_WKS[$i]}")"; fi ;;
    5h*)
      if [[ "$sel" == "0" ]]; then printf '5h window spent'
      else printf '5h %s%% left' "$sel"; fi ;;
    'incomplete usage data')      printf 'incomplete data' ;;
    'already the active account') printf 'already active' ;;
    *'its home IS the shared'*)   printf 'home is ~/.claude' ;;
    *)
      # everything left is "no LIVE numbers (<why>)", the WHY is the part worth
      # a column.
      #
      # ⚠️ THIS ARM USED TO PRINT "weekly window expired" FOR EVERY STALE ROW,
      # AND THAT ONE STRING WAS THREE DIFFERENT FACTS WEARING ONE COAT:
      #   - the SEAT has ended            -> genuinely finished
      #   - the weekly quota is SPENT     -> back at the named reset
      #   - the MEASUREMENT is stale      -> unknown, and very possibly FULL
      # Only the first two are bad news. The third is an instruction to go and
      # measure, and it read as an obituary: every session that saw it wrote off
      # two cancelled-but-live seats carrying roughly two more full weekly
      # refreshes each. See the seat-lifecycle block near the top.
      if seat_ended "$i"; then
        printf 'seat ended %s' "$(seat_ends_on "$i")"; return 0
      fi
      if (( U_WKX[i] == 1 )); then
        # Never "expired", the WINDOW rolled, which is the opposite of bad: the
        # quota behind it is new and unmeasured. This arm is the one exception to
        # the 22-char rule below at 23 chars, and it only ever renders in the
        # UNMEASURED bucket, whose renderer pads its reason column to 23 to match.
        printf 'unmeasured, may be full'; return 0
      fi
      # every arm is <= the 22-char reason column, so a long reason never pushes
      # the "back <when>" column out of alignment on the row that has one
      case "$why" in
        # CLEARED/rejected BEFORE absent: three different defects, three different
        # fixes, and 2026-08-07 proved that collapsing them into "no stored
        # credential" costs an hour of hunting for a login that already happened.
        # All of these fit the 22-char reason column.
        *'was CLEARED'*|*'refresh rejected'*|*'refresh already rejected'*)
                                     printf 'cleared, needs login' ;;
        *'no stored credential'*)    printf 'no stored credential' ;;
        # stale BEFORE 429: an expired token's reason quotes the HTTP code the vendor
        # refused it with (429, measured 2026-08-30), and "rate-limited" would send
        # the operator waiting a minute for a number that never comes
        # reserved BEFORE stale/429: the seat is unmeasured because this box may
        # not nudge it, not because anything is wrong with it; its owner answers
        *'reserved seat'*)           printf 'reserved seat' ;;
        *'stored token is stale'*)   printf 'stored token stale' ;;
        *429*)                       printf 'usage API rate-limited' ;;
        # printf '%s', not a bare literal: a leading "--" would be eaten as an
        # option and the column would render EMPTY
        *'--no-refresh'*)            printf '%s' '--no-refresh (cached)' ;;
        *'unexpected usage schema'*) printf 'unexpected API schema' ;;
        *)                           printf 'no live numbers' ;;
      esac ;;
  esac
}

# WHEN does an unavailable account come back? The window that is actually
# blocking it, never simply the weekly one: a 5h-spent account is usable again
# in an hour, and saying "back Thursday" about it would be wrong. Empty when
# nothing is blocking by the numbers (a stale token comes back when it rotates,
# not on a clock), so the column stays honest instead of inventing a deadline.
comeback_iso() {  # comeback_iso <slot-index>
  local i="$1" wkl sel
  wkl="$(remaining "${U_WKU[$i]}")"; sel="$(remaining "${U_SEU[$i]}")"
  if [[ -n "$wkl" ]] && (( U_WKX[i] == 0 )) && (( wkl < MIN_WEEKLY )) && [[ -n "${U_WKR[$i]}" ]]; then
    printf '%s' "${U_WKR[$i]}"; return 0
  fi
  if [[ -n "$sel" ]] && (( U_SEX[i] == 0 )) && (( sel < MIN_SESSION )) && [[ -n "${U_SER[$i]}" ]]; then
    printf '%s' "${U_SER[$i]}"; return 0
  fi
  return 0
}

# reset_phrase for a SLOT's WEEKLY window, which is the one window that can carry
# a projection: the measured instant when the API named one, else the projected
# one marked `~`, else reset_phrase's honest "no active window yet". Only the
# weekly side has this; a 5h window is far too short to project a cadence from.
weekly_reset_phrase() {  # weekly_reset_phrase <slot-index>
  local i="${1:-}"
  if [[ -z "${U_WKR[$i]:-}" && -n "${U_WKP[$i]:-}" ]]; then
    printf 'resets ~%s' "$(fmt_reset "${U_WKP[$i]}")"; return 0
  fi
  reset_phrase "${U_WKR[$i]:-}"
}

# Everything the default view relocated rather than deleted. Same labels the old
# dashboard used (slot / note / why / skipped), one indent deeper so it reads as
# detail hanging off its row.
render_verbose_detail() {  # render_verbose_detail <slot-index>
  (( VERBOSE )) || return 0
  local i="$1" pfx='      '
  printf '%s\n' "$(paint "$CLR_DIM" "${pfx}slot    ${LABELS[$i]} · $(tilde "${DIRS[$i]}")")"
  if [[ "${U_STATE[$i]}" != "dup" ]]; then
    printf '%s\n' "$(paint "$CLR_DIM" "${pfx}resets  weekly $(weekly_reset_phrase "$i") · 5h $(reset_phrase "${U_SER[$i]}")")"
  fi
  [[ -n "${U_VIA[$i]}" ]] && printf '%s\n' "$(paint "$CLR_DIM" "${pfx}note    ${U_VIA[$i]}")"
  [[ "${U_STATE[$i]}" != "live" && -n "${U_WHY[$i]}" ]] \
    && printf '%s\n' "$(paint "$CLR_DIM" "${pfx}why     ${U_WHY[$i]}")"
  if (( U_REC[i] == 0 )) && [[ -n "${U_REASON[$i]}" ]]; then
    printf '%s\n' "$(paint "$CLR_DIM" "${pfx}skipped ${U_REASON[$i]}")"
  fi
  [[ -n "${U_EMAIL[$i]}" && "${U_EMAIL[$i]}" != "${LABELS[$i]}" ]] \
    && printf '%s\n' "$(paint "$CLR_YELLOW" "${pfx}⚠ this dir is logged in as ${U_EMAIL[$i]}, not the label above")"
  return 0
}

# The closing recommendation sentence, lifted OUT of render_usage verbatim so the
# `--json` view can publish the very same rationale instead of a paraphrase that
# drifts from it. render_usage still prints exactly these bytes, in exactly this
# place; json_usage captures them and collapses the (at most two) lines into one.
# Which of the two modes produced the sentence above, and the numbers that chose it.
# Printed on EVERY recommendation, stay or switch: "why is it telling me this" is the
# question a two-mode rule creates, and answering it only in one branch is how the two
# modes become indistinguishable in practice.
mode_note() {
  local pool
  # what the auto-trigger SAW, stated as an observation rather than as the reason,
  # so a FORCED mode can report it without also claiming a comparison the override
  # just bypassed (a forced floor run with cs at 31% must not say "at or above the
  # 50% comfortable mark", which is plainly false)
  if [[ -n "$BEST_ALT_PCT" ]]; then
    pool="$(printf 'best other account %s at %s%% weekly left, comfortable mark %s%%' \
      "$BEST_ALT_EMAIL" "$BEST_ALT_PCT" "$COMFORTABLE_PCT")"
  else
    pool="no other account has usable weekly numbers"
  fi
  if (( REC_MODE_FORCED )); then
    if [[ "$REC_MODE" == "burn-down" ]]; then
      printf '  mode: burn-down (forced by CLAUDE_FAILOVER_MODE), the active account gets spent down to ~%s%% left first, whatever the pool looks like (%s).\n' \
        "$EXHAUSTED_PCT" "$pool"
    else
      printf '  mode: floor (forced by CLAUDE_FAILOVER_MODE), the >=%s%%-left floor governs, whatever the pool looks like (%s).\n' \
        "$MIN_WEEKLY" "$pool"
    fi
  elif [[ "$REC_MODE" == "burn-down" ]]; then
    printf '  mode: burn-down, nowhere comfortable to go (%s), so the active account gets spent out instead of abandoned with room in it.\n' \
      "$pool"
  else
    printf '  mode: floor, there IS somewhere good to go (%s), so moving off early costs nothing and the >=%s%%-left floor governs as usual.\n' \
      "$pool" "$MIN_WEEKLY"
  fi
}

# The PICK's own deadline, rendered, and marked `~` when it is a projection.
#
# ⚠️ ONE HELPER, BECAUSE THIS STRING IS PUBLISHED VERBATIM. recommendation_text's
# output is `recommendation.reason` in `usage --json`, which `cl` and pocketmux
# read, so an unmarked projected instant in this sentence is the same lie on the
# machine surface as on the human one - and worse, because a parser cannot see
# the table's legend. Every place that names REC_RESET goes through here.
rec_reset_when() {
  local mark=""
  (( REC_PROJECTED )) && mark="~"
  printf '%s%s' "$mark" "$(fmt_reset "$REC_RESET")"
}

recommendation_text() {
  local alias_of act_note="" awkl awku awkb
  # closing recommendation, it ALWAYS states the active account's standing, in
  # all three shapes (stay put / switch because it's nearly exhausted / switch
  # because another account's headroom expires sooner). Before this, act_note
  # only populated when the active account was under the health floor, so a
  # switch recommended purely because another account resets sooner named the
  # target and left "what am I currently on" unsaid.
  if (( SHARED_SLOT >= 0 )) && [[ "${U_STATE[$SHARED_SLOT]}" == "live" ]]; then
    awkl="$(remaining "${U_WKU[$SHARED_SLOT]}")"
    if [[ -n "$awkl" ]]; then
      awku="$(used "${U_WKU[$SHARED_SLOT]}")"
      # the binding limit rides INSIDE the parenthetical rather than as its own
      # bracket, so the sentence never ends in two adjacent parenthesised clauses
      awkb=""
      [[ -n "${U_WKS[$SHARED_SLOT]}" ]] && awkb="binding: ${U_WKS[$SHARED_SLOT]}, "
      # weekly_reset_phrase, not reset_phrase: the active account's own window can
      # be the untouched one, and this clause has to name its projected reset
      # (marked) rather than claim nothing is expiring.
      if (( awkl < MIN_WEEKLY )); then
        act_note=" The active account ${U_EMAIL[$SHARED_SLOT]} is nearly exhausted (weekly ${awku}% used · ${awkl}% left, ${awkb}$(weekly_reset_phrase "$SHARED_SLOT"))."
      else
        act_note=" The active account ${U_EMAIL[$SHARED_SLOT]} is at weekly ${awku}% used · ${awkl}% left (${awkb}$(weekly_reset_phrase "$SHARED_SLOT"))."
      fi
    fi
  fi
  # The one case where the burn-down rule does NOT keep him where he is: weekly still
  # has room, but the 5h session window is spent, so he is blocked RIGHT NOW and only
  # a switch unblocks him. It replaces act_note rather than adding to it, the generic
  # "is nearly exhausted / is at weekly N% left" line would otherwise say the opposite
  # of the sentence it sits next to, and the whole point is naming WHICH window
  # caused the switch.
  if (( BURN_BLOCKED )) && (( SHARED_SLOT >= 0 )); then
    local bnote=""
    [[ -n "${U_WKS[$SHARED_SLOT]}" ]] && bnote="binding: ${U_WKS[$SHARED_SLOT]}, "
    act_note="$(printf ' The active account %s still has weekly headroom (%s%% used · %s%% left, %s%s), but its 5h window is spent (%s%% used · %s%% left, %s), blocked right now, which is the one case where switching beats spending the week down.' \
      "${U_EMAIL[$SHARED_SLOT]}" "$(used "${U_WKU[$SHARED_SLOT]}")" "$BURN_WKL" \
      "$bnote" "$(weekly_reset_phrase "$SHARED_SLOT")" \
      "$(used "${U_SEU[$SHARED_SLOT]}")" "$BURN_SEL" "$(reset_phrase "${U_SER[$SHARED_SLOT]}")")"
  fi
  if (( REC_HOLD )); then
    # Burn-down hold: he stays put until the weekly window is ~fully spent. This is
    # the sentence that has to make the NEW rule obvious, so it says the number, the
    # deadline it is racing, the threshold that ends the hold, and where he goes next.
    local when_clause next_note="" cache_note="" sess_note=""
    if [[ -n "${U_WKR[$SHARED_SLOT]}" ]]; then
      when_clause="spend it down before it $(reset_phrase "${U_WKR[$SHARED_SLOT]}")"
    elif [[ -n "${U_WKP[$SHARED_SLOT]:-}" ]]; then
      # "nothing is expiring" is what a KNOWN cadence disproves: the window has
      # not started, and it still dies at the projected instant, which is exactly
      # the date a burn-down hold is racing.
      when_clause="its weekly window has not started yet, and on this seat's own cadence it is lost ~$(fmt_reset "${U_WKP[$SHARED_SLOT]}")"
    else
      when_clause="its weekly window has not started yet, so nothing is expiring"
    fi
    [[ -n "$BURN_SEL" ]] && sess_note="$(printf ' 5h %s%% used · %s%% left, %s.' \
      "$(used "${U_SEU[$SHARED_SLOT]}")" "$BURN_SEL" "$(reset_phrase "${U_SER[$SHARED_SLOT]}")")"
    # shellcheck disable=SC2016  # literal backticks around the command to run
    [[ -n "$REC_NEXT_EMAIL" ]] && next_note="$(printf ' Then `rota switch` moves to %s (`rota switch %s`).' \
      "$REC_NEXT_EMAIL" "$REC_NEXT_ALIAS")"
    if (( BURN_CACHED )); then
      # same distinction as the optimizer-pick line: a borrowed number says whose
      # it is, a remembered one says how old it is, and neither pretends to be live
      if [[ "${U_STATE[$SHARED_SLOT]}" == "peer" ]]; then
        cache_note=" [not a live measurement: $(state_tag "$SHARED_SLOT")]"
      else
        cache_note=" [from CACHED numbers, ${U_TS[$SHARED_SLOT]:-age unknown}]"
      fi
    fi
    printf '→ stay on %s: weekly %s%% used · %s%% left%s, %s; switch at ~%s%% left.%s%s%s\n' \
      "$REC_EMAIL" "$(used "${U_WKU[$SHARED_SLOT]}")" "$BURN_WKL" \
      "$(scope_note "${U_WKS[$SHARED_SLOT]}")" "$when_clause" "$EXHAUSTED_PCT" \
      "$sess_note" "$next_note" "$cache_note"
  elif (( REC_SLOT < 0 )); then
    printf '→ nothing to recommend: no account has LIVE numbers clearing the health floor (>=%s%% weekly, >=%s%% 5h left). See the per-row reasons above.%s\n' \
      "$MIN_WEEKLY" "$MIN_SESSION" "$act_note"
  elif (( REC_SLOT == SHARED_SLOT )); then
    # A FRESH pick has no reset time, so "no healthier account resets sooner" would be
    # naming an instant that does not exist. Say what is actually true of it instead.
    if (( REC_FRESH )) && (( REC_PROJECTED )); then
      # BOTH facts, because both are true and each one alone misleads: the window
      # really has not started (so "resets in 2d" would overstate what is known),
      # and it really does die on the seat's own cadence (so "nothing is expiring"
      # would understate what is at stake).
      printf '→ stay on %s: it is already active, its weekly window has not started yet (weekly %s%% used · %s%% left; 5h %s%% used · %s%% left); on this seat'"'"'s own cadence that untouched week is lost %s, and no healthier account has headroom expiring sooner.%s\n' \
        "$REC_EMAIL" "$(used "${U_WKU[$REC_SLOT]}")" "$(remaining "${U_WKU[$REC_SLOT]}")" \
        "$(used "${U_SEU[$REC_SLOT]}")" "$(remaining "${U_SEU[$REC_SLOT]}")" \
        "$(rec_reset_when)" "$act_note"
    elif (( REC_FRESH )); then
      printf '→ stay on %s: it is already active, its weekly window has not started yet (weekly %s%% used · %s%% left; 5h %s%% used · %s%% left) and no healthier account has headroom expiring sooner.%s\n' \
        "$REC_EMAIL" "$(used "${U_WKU[$REC_SLOT]}")" "$(remaining "${U_WKU[$REC_SLOT]}")" \
        "$(used "${U_SEU[$REC_SLOT]}")" "$(remaining "${U_SEU[$REC_SLOT]}")" "$act_note"
    else
      printf '→ stay on %s, it is already active, clears the health floor (weekly %s%% used · %s%% left; 5h %s%% used · %s%% left) and no healthier account resets sooner.%s\n' \
        "$REC_EMAIL" "$(used "${U_WKU[$REC_SLOT]}")" "$(remaining "${U_WKU[$REC_SLOT]}")" \
        "$(used "${U_SEU[$REC_SLOT]}")" "$(remaining "${U_SEU[$REC_SLOT]}")" "$act_note"
    fi
  else
    alias_of="$(basename "${DIRS[$REC_SLOT]}")"
    # shellcheck disable=SC2016  # literal backticks around the command to run
    printf '→ switch to %s: `rota switch %s`\n' "$REC_EMAIL" "$alias_of"
    # ⚠️ SEAT-END IS TESTED FIRST, and that order is load-bearing since REC_FRESH
    # became a fact about the WINDOW. A fresh window on a seat whose END DATE bound
    # the pick used to fall through here because REC_FRESH was derived from the
    # deadline; now both can be true at once, and the sentence that must win is the
    # one naming the date that actually chose this seat.
    if [[ "$REC_DEADLINE_KIND" == "seat-end" ]]; then
      # ⚠️ NAME THE DATE THAT ACTUALLY BOUND THE CHOICE. The ranking is
      # min(weekly reset, seat end), so on a cancelled seat's FINAL partial week
      # the winner is chosen by its END DATE - and this sentence used to call
      # that "soonest weekly reset" regardless: the right answer under the wrong
      # noun, pointing the reader at a date that had nothing to do with the
      # pick. REC_DEADLINE_KIND comes straight out of rota_seat_deadline, the
      # same call that produced the ordering, so the sentence and the sort can
      # never name different dates.
      printf '  soonest deadline among the accounts clearing the health floor: this seat ENDS %s, before its weekly window would reset, so this is its LAST window (weekly %s%% used · %s%% left; 5h %s%% used · %s%% left) and whatever is unspent on it is gone for good.%s\n' \
        "$(seat_ends_on "$REC_SLOT")" \
        "$(used "${U_WKU[$REC_SLOT]}")" "$(remaining "${U_WKU[$REC_SLOT]}")" \
        "$(used "${U_SEU[$REC_SLOT]}")" "$(remaining "${U_SEU[$REC_SLOT]}")" "$act_note"
    elif (( REC_FRESH )) && (( REC_PROJECTED )); then
      # A fully unspent account that nonetheless has the soonest deadline, which
      # is the whole point of projecting: both facts, one sentence, and the
      # instant marked because this box computed it rather than read it.
      printf '  a fully unspent account whose untouched week dies first: its weekly window has not started yet (weekly %s%% used · %s%% left; 5h %s%% used · %s%% left) and on this seat'"'"'s own cadence it is lost %s, sooner than any other account clearing the health floor.%s\n' \
        "$(used "${U_WKU[$REC_SLOT]}")" "$(remaining "${U_WKU[$REC_SLOT]}")" \
        "$(used "${U_SEU[$REC_SLOT]}")" "$(remaining "${U_SEU[$REC_SLOT]}")" \
        "$(rec_reset_when)" "$act_note"
    elif (( REC_FRESH )); then
      printf '  a fully unspent account: its weekly window has not started yet (weekly %s%% used · %s%% left; 5h %s%% used · %s%% left), and no account clearing the health floor has headroom expiring sooner.%s\n' \
        "$(used "${U_WKU[$REC_SLOT]}")" "$(remaining "${U_WKU[$REC_SLOT]}")" \
        "$(used "${U_SEU[$REC_SLOT]}")" "$(remaining "${U_SEU[$REC_SLOT]}")" "$act_note"
    else
      printf '  soonest weekly reset among the accounts clearing the health floor (weekly %s%% used · %s%% left; 5h %s%% used · %s%% left, resets %s), so that headroom gets spent before it expires.%s\n' \
        "$(used "${U_WKU[$REC_SLOT]}")" "$(remaining "${U_WKU[$REC_SLOT]}")" \
        "$(used "${U_SEU[$REC_SLOT]}")" "$(remaining "${U_SEU[$REC_SLOT]}")" \
        "$(rec_reset_when)" "$act_note"
    fi
  fi
  mode_note
}

# The per-account PICTURE: the active-account header block, then one block per
# account (both windows in both polarities, live-vs-cached marker, provenance,
# and the reason the row was skipped). Split out of render_usage, which is now
# exactly this plus recommendation_text, so `switch-auto` can print the SAME
# table before its own decision instead of ending on "see `rota usage`" and making
# you run a second command to learn where the other accounts stand.
#
# ONE renderer, deliberately: two surfaces that describe the same pool must not be
# able to describe it differently, which is the whole reason this is an extraction
# and not a second table written for switch-auto.
# ── the `billing now:` header (pool v2) ──────────────────────────────────────
# The claim in ~/.claude.json says which account NEW launches resolve; the only
# thing that says which account is being SPENT right now is the set of live
# claude processes and the identity of the dir each is pinned to. One line,
# derived from `ps eww` (live_claude_pins) + config_email per pinned dir, with
# a loud warning when what is billing differs from what the claim says, the
# exact gap the 2026-08-11 personal/work incident hid for weeks.
render_billing_now() {
  local rows claim="" seg="" mismatch=0 count dir email seen=""
  rows="$(live_claude_pins | awk '{ print $2 }' | sort | uniq -c)"
  claim="$(json_email "$HOME/.claude.json")"
  if [[ -z "$rows" ]]; then
    printf '  %s\n' "$(paint "$CLR_DIM" 'billing now: no live pinned claude session')"
    return 0
  fi
  while read -r count dir; do
    [[ -n "$dir" ]] || continue
    email="$(config_email "$dir")"
    seg="${seg:+$seg; }${email:-unknown} ($count pinned to $(tilde "$dir"))"
    if [[ -n "$email" ]]; then
      case " $seen " in *" $email "*) ;; *) seen="$seen $email" ;; esac
      [[ -n "$claim" && "$email" != "$claim" ]] && mismatch=1
    fi
  done <<<"$rows"
  printf '  %s\n' "$(paint "$CLR_BOLD" "billing now: $seg")"
  if (( mismatch )); then
    printf '  %s\n' "$(paint "$CLR_RED" "⚠ BILLING ≠ CLAIM: live sessions above are spending${seen}, but ~/.claude.json claims ${claim:-no account}, new launches land elsewhere than the money goes. Run \`rota reconcile\` / restart stale panes.")"
  fi
  return 0
}

render_usage_table() {
  local i n ew=22 alts="" unav="" w warned=0

  # the widest email decides every column, so ACTIVE, ALTERNATIVES and
  # UNAVAILABLE line up as one table rather than three
  for i in "${!DIRS[@]}"; do
    n=${#U_EMAIL[$i]}; (( n > ew )) && ew="$n"
  done

  printf '%s\n\n' "$(paint "$CLR_BOLD" "Claude account pool, $(date '+%a %-d %b %H:%M %Z')")"
  render_billing_now
  render_boosts
  echo

  # Warnings stay in the DEFAULT view, they are rare, and they are the reason
  # the numbers below might belong to a different account than the label says.
  # Only the routine identity/fingerprint line moved behind --verbose.
  for w in "$SHARED_WARN" "$AUTH_WARN" "$NESTED_WARN"; do
    [[ -n "$w" ]] || continue
    printf '%s\n' "$(paint "$CLR_YELLOW" "  $w")"
    warned=1
  done
  (( warned )) && echo

  if (( VERBOSE )); then
    # shellcheck disable=SC2016  # literal backticks in the sentence, nothing to expand
    printf '  %s\n' "$(paint "$CLR_DIM" 'active account (the shared ~/.claude credential, every plain `claude` session, including all running ones):')"
    printf '  %s\n' "$(paint "$CLR_DIM" "  ${SHARED_EMAIL:-UNKNOWN}")"
    [[ -n "$SHARED_SOURCE" ]] && printf '  %s\n' "$(paint "$CLR_DIM" "  identity: $SHARED_SOURCE")"
    echo
  fi

  # ── 1. ACTIVE: what am I on, and how much of it is left ────────────────────
  if (( SHARED_SLOT >= 0 )); then
    printf '%s   %s  %s\n' \
      "$(paint "$CLR_BOLD$CLR_CYAN" '▶ ACTIVE')" \
      "$(paint "$CLR_BOLD" "$(printf '%-*s' "$ew" "${U_EMAIL[$SHARED_SLOT]}")")" \
      "$(paint "$CLR_DIM" "[$(state_tag "$SHARED_SLOT")]")"
    if [[ "${U_STATE[$SHARED_SLOT]}" == "dup" ]]; then
      printf '    %s\n' "same account as ${LABELS[${U_DUP[$SHARED_SLOT]}]}"
    else
      render_active_window "weekly" "${U_WKU[$SHARED_SLOT]}" "${U_WKR[$SHARED_SLOT]}" \
        "${U_WKX[$SHARED_SLOT]}" "${U_WKS[$SHARED_SLOT]}" "${U_WKP[$SHARED_SLOT]:-}"
      render_active_window "5h" "${U_SEU[$SHARED_SLOT]}" "${U_SER[$SHARED_SLOT]}" "${U_SEX[$SHARED_SLOT]}"
    fi
    render_verbose_detail "$SHARED_SLOT"
  else
    printf '%s   %s\n' "$(paint "$CLR_BOLD$CLR_CYAN" '▶ ACTIVE')" \
      "$(paint "$CLR_YELLOW" "${SHARED_EMAIL:-UNKNOWN, could not identify the shared ~/.claude credential}")"
    [[ -n "$SHARED_EMAIL" ]] \
      && printf '    %s\n' "$(paint "$CLR_DIM" 'not one of the configured pool accounts, no windows to show')"
  fi
  echo

  # ── 2/3/4. the split ───────────────────────────────────────────────────────
  #
  # ⚠️ THERE IS A THIRD PLACE A ROW CAN GO, AND ADDING IT IS THE POINT OF THIS
  # REPORT. "UNAVAILABLE" is a verdict about the ACCOUNT, and only two of the
  # three not-recommendable states are actually about the account: the seat has
  # ended, or the quota is spent. The third, "I have not measured this", is a
  # statement about THIS TOOL, and filing it under UNAVAILABLE told every reader
  # the opposite of the truth about two seats that were fully loaded.
  #
  # So an unmeasured seat goes to a bucket that INVITES a measurement instead of
  # pronouncing on the account.
  local unmeas=""
  for i in "${!DIRS[@]}"; do
    (( SHARED_SLOT >= 0 )) && (( i == SHARED_SLOT )) && continue
    if (( U_REC[i] == 1 )); then alts="$alts $i"
    elif seat_ended "$i"; then unav="$unav $i"
    elif weekly_unknown "$i" && [[ "${U_STATE[$i]}" != "dup" ]]; then unmeas="$unmeas $i"
    else unav="$unav $i"; fi
  done

  printf '  %s%s\n' "$(paint "$CLR_BOLD" 'ALTERNATIVES')" \
    "$(paint "$CLR_DIM" ', have capacity, switch anytime')"
  if [[ -n "$alts" ]]; then
    for i in $alts; do render_alt_row "$i" "$ew"; render_verbose_detail "$i"; done
  else
    printf '  %s\n' "$(paint "$CLR_DIM" 'none, no other account clears the health floor right now')"
  fi
  echo

  if [[ -n "$unmeas" ]]; then
    printf '  %s%s\n' "$(paint "$CLR_BOLD" 'UNMEASURED')" \
      "$(paint "$CLR_DIM" ', quota UNKNOWN, not spent. Very possibly full; go and look')"
    for i in $unmeas; do render_unmeasured_row "$i" "$ew"; render_verbose_detail "$i"; done
    echo
  fi

  printf '  %s\n' "$(paint "$CLR_BOLD" 'UNAVAILABLE')"
  if [[ -n "$unav" ]]; then
    for i in $unav; do render_unavail_row "$i" "$ew"; render_verbose_detail "$i"; done
  else
    printf '  %s\n' "$(paint "$CLR_DIM" 'none, every other account has capacity')"
  fi
  echo
  render_projection_legend
  return 0
}

# Does THIS slot's weekly reset print as a projection? One predicate, so the mark
# and the legend that explains it are decided by the same test.
slot_projected() {  # slot_projected <slot-index>
  [[ -z "${U_WKR[$1]:-}" && -n "${U_WKP[$1]:-}" ]]
}

# ONE line explaining the `~`, and only when a `~` is actually ON THE PAGE.
#
# ⚠️ THE GATE IS WHAT WAS RENDERED, NOT WHAT THE POOL CONTAINS. The default table
# prints a weekly reset for the ACTIVE row only: render_alt_row and
# render_unavail_row print no reset at all, so scanning every slot announced a
# legend for a mark nowhere on the page whenever an idle seat projected and the
# active one had a real instant. --verbose is the case where every slot can show
# one, because render_verbose_detail prints a `resets` line per row.
render_projection_legend() {
  local i
  if (( VERBOSE )); then
    for i in "${!DIRS[@]}"; do
      slot_projected "$i" || continue
      print_projection_legend; return 0
    done
    return 0
  fi
  (( SHARED_SLOT >= 0 )) || return 0
  slot_projected "$SHARED_SLOT" || return 0
  print_projection_legend
}

print_projection_legend() {
  printf '  %s\n\n' "$(paint "$CLR_DIM" "~ projected: window untouched since it rolled, so the vendor reports no reset yet; date = the seat's last known reset rolled forward a week at a time")"
}

# recommendation_text is left byte-for-byte alone on purpose: `usage --json`
# publishes its output VERBATIM as recommendation.reason, so a colour code
# emitted inside it would end up in the JSON a phone renderer parses. Colour is
# therefore applied here, at the call site, by line shape, the `→` verdict
# bold, the `mode:` explanation dim, and the JSON path never sees it.
render_recommendation() {
  local line
  recommendation_text | while IFS= read -r line; do
    case "$line" in
      '→'*)       printf '%s\n' "$(paint "$CLR_BOLD" "$line")" ;;
      '  mode:'*) printf '%s\n' "$(paint "$CLR_DIM" "$line")" ;;
      *)          printf '%s\n' "$line" ;;
    esac
  done
}

# ── the PANES block: the half of "which account am I on" this table can't see ──
# A tmux pane list shows PANES; Claude Code's own statusline says
# "Session: 93%" and means the 5-HOUR USAGE BLOCK. One word, two unrelated
# things, which is exactly why the operator could not tell whether the account
# view or the pane view was the one wanted (2026-08-07). The fix is to stop
# making them choose: the account view now ends with a one-glance PANE summary.
#
# It matters MOST right after a switch: swapping the shared credential does not
# reach into a running session. A pane adopts the new account only when its
# claude process reloads the credential, in practice, on restart. So the block
# also rides along at the end of `switch`, where "restart to adopt" is the next
# action rather than a footnote.
#
# ONE renderer, reused by both surfaces, for the same reason render_usage_table
# is: two views of the same panes must not be able to disagree.
#
# WITHOUT A CONFIGURED SESSION IT IS A SILENT NO-OP. The tmux session name comes
# from ROTA_TMUX_SESSION; unset means pane convergence is a silent no-op
# and has NO default: when it is empty, panes_scan() returns 1 before touching
# tmux, and not a byte is printed, no "n/a" row, no warning. Same when the named
# session does not exist, and for a box with no tmux at all. Pane convergence is
# an optional feature, switched on by naming the session.
PANES_SESSION="${ROTA_TMUX_SESSION:-}"
PANES_US=$'\037'
# How long --restart-idle waits for a pane's shell to come back after /quit.
PANE_RESTART_TRIES="${ROTA_PANE_RESTART_TRIES:-20}"
PANE_RESTART_SLEEP="${ROTA_PANE_RESTART_SLEEP:-1}"
# Where Claude Code keeps its transcripts, <projects>/<cwd-slug>/<session-id>
# .jsonl (every pool dir's `projects` is a link here, see POOL_LINKS), read by
# pane_resume_target to turn a pane title into the session id to resume.
# Overridable for tests, same shape as CLAUDE_POOL_DIR.
PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

# When the shared credential last CHANGED on disk, i.e. the last moment a
# running session could have been left holding the previous account. 0 when it
# can't be read, which disables the "may still be on the previous account"
# heuristic rather than guessing.
#
# The LATER of mtime and ctime, deliberately, because mtime alone is wrong for
# the one case this exists to cover: switch-all writes the new credential with
# `cp -p`, which PRESERVES the source pool copy's mtime, so a swap to an
# account whose pool copy was last rotated three days ago would leave the shared
# file claiming an mtime of three days ago, and the heuristic would report zero
# stale panes seconds after a switch. ctime cannot be preserved that way (the
# copy + its chmod are metadata changes), so max() reads as "this file last
# changed at T" under both writers. It can only ever flag MORE panes, never
# fewer, which is the safe direction for a hint worded "may still be".
cred_changed_at() {
  local f="$HOME/.claude/.credentials.json" m c
  m="$(stat -f %m "$f" 2>/dev/null || true)"
  c="$(stat -f %c "$f" 2>/dev/null || true)"
  [[ "$m" =~ ^[0-9]+$ ]] || m="$(stat -c %Y "$f" 2>/dev/null || true)"
  [[ "$c" =~ ^[0-9]+$ ]] || c="$(stat -c %Z "$f" 2>/dev/null || true)"
  [[ "$m" =~ ^[0-9]+$ ]] || m=0
  [[ "$c" =~ ^[0-9]+$ ]] || c=0
  (( c > m )) && m="$c"
  printf '%s' "$m"
}

# Start time (epoch) of the `claude` process living on a pane's tty, or 0 when
# there isn't one / it can't be parsed. The PANE's own shell pid is the wrong
# signal here: a pane restarted with `claude --resume` keeps the same shell, so
# only the claude process's start time says anything about which credential it
# loaded.
pane_claude_started() {  # pane_claude_started <pane-tty, e.g. /dev/ttys003>
  local tty="${1:-}" stamp secs
  [[ -n "$tty" ]] || { printf '0'; return 0; }
  # lstart is five whitespace-separated fields ("Thu Aug  6 23:46:43 2026"),
  # ucomm the sixth, awk reassembles the five rather than trusting column
  # positions, and drops the trailing spaces `date -j` would complain about.
  stamp="$(ps -t "${tty#/dev/}" -o lstart=,ucomm= 2>/dev/null \
            | awk '$6 ~ /^claude(\.exe)?$/ { printf "%s %s %s %s %s", $1, $2, $3, $4, $5; exit }' \
            || true)"
  [[ -n "$stamp" ]] || { printf '0'; return 0; }
  secs="$(date -j -f '%a %b %e %H:%M:%S %Y' "$stamp" +%s 2>/dev/null || true)"
  [[ "$secs" =~ ^[0-9]+$ ]] || secs="$(date -d "$stamp" +%s 2>/dev/null || true)"
  [[ "$secs" =~ ^[0-9]+$ ]] || secs=0
  printf '%s' "$secs"
}

# THE one definition of "this pane is mid-work", used by BOTH the summary's
# `working` count and --restart-idle's skip rule, so the count you read can
# never disagree with the pane the restart refuses to touch.
#
# `esc to interrupt` is on screen for the whole time claude is actively doing
# something (the same marker other pane watchers key on), and
# `Compacting` covers the one long operation that does not print it. The third
# alternative is deliberately included even though it is quieter: a pane WAITING
# ON BACKGROUND/DYNAMIC SUBAGENTS shows neither of the first two, yet /quit-ing
# it kills that work just as dead, and "never destroy work in flight" is the
# rule this function exists to enforce. Erring toward MORE skips is the safe
# direction: the cost of a false "working" is one pane you restart by hand.
PANE_WORKING_RE='esc to interrupt|Compacting|Waiting for [0-9]+ (background|dynamic)|Waiting for task \(esc to give'

# ── tmux, resolved for launchd contexts (keeper polish, 2026-08-12) ──────────
# Live evidence: the keeper's auto-switch ran "--restart-idle: no '<session>'
# tmux session here" while `tmux ls` in a user shell showed the session with
# four windows attached. Under launchd the job PATH may miss the Homebrew dir
# (tmux unfindable) and the default server socket may not resolve, and the
# old message collapsed all of that into "no session", which reads as "nothing
# to do" when the truth was "could not even look".
#
# resolve_tmux finds the binary (PATH, then the two Homebrew prefixes;
# CLAUDE_FAILOVER_TMUX_BIN is the test override), tmuxc() runs it with an
# explicit -S <default user socket> fallback when the default resolution
# cannot reach a server, and PANES_UNAVAIL_REASON says WHICH of the three
# failures happened: binary not found / server unreachable / no such session.
TMUX_BIN=""
TMUX_SOCK_ARGS=()
resolve_tmux() {
  [[ -n "$TMUX_BIN" ]] && return 0
  if [[ -n "${CLAUDE_FAILOVER_TMUX_BIN:-}" ]]; then
    [[ -x "$CLAUDE_FAILOVER_TMUX_BIN" ]] || return 1
    TMUX_BIN="$CLAUDE_FAILOVER_TMUX_BIN"
    return 0
  fi
  if command -v tmux >/dev/null 2>&1; then TMUX_BIN="$(command -v tmux)"
  elif [[ -x /opt/homebrew/bin/tmux ]]; then TMUX_BIN=/opt/homebrew/bin/tmux
  elif [[ -x /usr/local/bin/tmux ]]; then TMUX_BIN=/usr/local/bin/tmux
  else return 1; fi
}

tmuxc() {  # tmux, through the resolved binary + any pinned socket
  resolve_tmux || return 127
  # ${arr[@]+…} guard: macOS bash 3.2 treats expanding an EMPTY array under
  # set -u as an unbound variable and aborts the whole script.
  "$TMUX_BIN" ${TMUX_SOCK_ARGS[@]+"${TMUX_SOCK_ARGS[@]}"} "$@"
}

# Can we reach a tmux SERVER at all? Tries the default resolution first, then
# pins the default per-user socket explicitly (launchd's environment can make
# tmux compute a different one). Sets PANES_UNAVAIL_REASON on failure.
PANES_UNAVAIL_REASON=""
tmux_server_reachable() {
  if tmuxc ls </dev/null >/dev/null 2>&1; then return 0; fi
  local sock
  sock="/private/tmp/tmux-$(id -u)/default"
  if [[ -e "$sock" ]]; then
    TMUX_SOCK_ARGS=(-S "$sock")
    if tmuxc ls </dev/null >/dev/null 2>&1; then return 0; fi
    TMUX_SOCK_ARGS=()
    PANES_UNAVAIL_REASON="tmux server unreachable (socket $sock did not answer)"
  else
    PANES_UNAVAIL_REASON="tmux server unreachable (no socket at $sock)"
  fi
  return 1
}

pane_is_working() {  # pane_is_working <pane-id>
  local pid="${1:-}"
  [[ -n "$pid" ]] || return 1
  tmuxc capture-pane -p -t "$pid" </dev/null 2>/dev/null | tail -20 \
    | grep -qE "$PANE_WORKING_RE"
}

# Strip the leading status glyph Claude Code writes into the pane title
# ("✳ rainbow rush game" → "rainbow rush game"). The glyph rotates, so this
# matches the whole spinner set rather than one character, and loops in case a
# title somehow carries two.
strip_pane_glyph() {
  local t="${1:-}"
  while :; do
    case "$t" in
      '✳ '*|'✻ '*|'✽ '*|'✶ '*|'✢ '*|'· '*|'⠁ '*|'⠂ '*|'⠄ '*|'⠆ '*|'⠇ '*|'⠈ '*|\
      '⠋ '*|'⠏ '*|'⠐ '*|'⠙ '*|'⠠ '*|'⠦ '*|'⠧ '*|'⠴ '*|'⠸ '*|'⠹ '*|'⠼ '*)
        t="${t#* }" ;;
      *) break ;;
    esac
  done
  while [[ "$t" == ' '* ]]; do t="${t# }"; done
  while [[ "$t" == *' ' ]]; do t="${t% }"; done
  printf '%s' "$t"
}

# One scan, memoised: both the summary and --restart-idle read the same rows, so
# a pane can never be counted `idle` by one and skipped as `working` by the
# other. Returns 1 (and prints nothing) when no tmux session is configured, the
# configured one does not exist,
# or it holds no claude panes.
PANES_SCANNED=0        # 0 = not yet · 1 = scanned, usable · 2 = scanned, nothing to show
PANES_TOTAL=0; PANES_IDLE=0; PANES_WORKING=0; PANES_PREV_ACCT=0
PANES_ROWS=""          # <pane-id> US <title> US <working 0|1> US <pre-switch 0|1> US <tty>, one per line
panes_scan() {
  case "$PANES_SCANNED" in 1) return 0 ;; 2) return 1 ;; esac
  PANES_SCANNED=2
  PANES_TOTAL=0; PANES_IDLE=0; PANES_WORKING=0; PANES_PREV_ACCT=0; PANES_ROWS=""
  PANES_UNAVAIL_REASON=""
  # no session name = the feature is off. Decided BEFORE tmux is even looked
  # for, so a box that never opted in pays nothing and prints nothing.
  if [[ -z "$PANES_SESSION" ]]; then
    PANES_UNAVAIL_REASON="no tmux session configured (set ROTA_TMUX_SESSION to the session holding your claude panes to enable pane convergence)"
    return 1
  fi
  if ! resolve_tmux; then
    PANES_UNAVAIL_REASON="tmux binary not found (PATH has no tmux, and neither /opt/homebrew/bin/tmux nor /usr/local/bin/tmux exists)"
    return 1
  fi
  tmux_server_reachable || return 1
  if ! tmuxc has-session -t "=$PANES_SESSION" </dev/null >/dev/null 2>&1; then
    PANES_UNAVAIL_REASON="no tmux session named '$PANES_SESSION' on this server"
    return 1
  fi
  local listing
  listing="$(tmuxc list-panes -s -t "=$PANES_SESSION" \
              -F "#{pane_id}${PANES_US}#{pane_tty}${PANES_US}#{pane_current_command}${PANES_US}#{pane_title}" \
              </dev/null 2>/dev/null || true)"
  [[ -n "$listing" ]] || { PANES_UNAVAIL_REASON="session '$PANES_SESSION' listed no panes"; return 1; }
  local cred; cred="$(cred_changed_at)"
  local pid tty cmd title working started
  while IFS="$PANES_US" read -r pid tty cmd title; do
    [[ -n "$pid" ]] || continue
    case "$cmd" in claude|claude.exe) ;; *) continue ;; esac
    PANES_TOTAL=$((PANES_TOTAL + 1))
    working=0; pane_is_working "$pid" && working=1
    if (( working )); then PANES_WORKING=$((PANES_WORKING + 1))
    else PANES_IDLE=$((PANES_IDLE + 1)); fi
    # THE HEURISTIC, and it is only that: a claude process that started BEFORE
    # the shared credential last changed cannot have loaded the current one at
    # startup. It may have picked it up since, on a token rotation, which is
    # why the sentence says "may still be". The SUMMARY never acts on it; the
    # restart itself belongs to the switch verbs (default) and pane-converge.
    started=0
    if (( cred > 0 )); then
      started="$(pane_claude_started "$tty")"
      if (( started > 0 )) && (( started < cred )); then
        PANES_PREV_ACCT=$((PANES_PREV_ACCT + 1))
        PANES_ROWS="${PANES_ROWS}${pid}${PANES_US}${title}${PANES_US}${working}${PANES_US}1${PANES_US}${tty}"$'\n'
        continue
      fi
    fi
    PANES_ROWS="${PANES_ROWS}${pid}${PANES_US}${title}${PANES_US}${working}${PANES_US}0${PANES_US}${tty}"$'\n'
  done <<<"$listing"
  (( PANES_TOTAL > 0 )) || return 1
  PANES_SCANNED=1
  return 0
}

render_panes_summary() {
  panes_scan || return 0
  echo
  printf '  %s  %s\n' "$(paint "$CLR_BOLD" 'PANES')" \
    "$(printf '%d total · %d idle · %d working' "$PANES_TOTAL" "$PANES_IDLE" "$PANES_WORKING")"
  if (( PANES_PREV_ACCT > 0 )); then
    printf '         %s\n' "$(paint "$CLR_YELLOW" \
      "$(printf '%d may still be on the previous account (started before the last switch), restart to adopt' "$PANES_PREV_ACCT")")"
  fi
  printf '         %s\n' "$(paint "$CLR_DIM" 'rota pane-converge --dry-run for detail')"
  return 0
}

# Wrap a session name for a `claude --resume "<name>"` command line typed into a
# pane by send-keys. Double quotes (not %q) so the line reads exactly as a human
# would type it; the four characters the shell still expands inside them are
# escaped.
dq_arg() {
  local s="${1:-}"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//\$/\\\$}"; s="${s//\`/\\\`}"
  printf '"%s"' "$s"
}

# Wait for a pane to fall back to its shell after /quit. Bounded: a pane that
# never lets go is LEFT ALONE, never force-killed.
pane_await_shell() {  # pane_await_shell <pane-id>
  local pid="${1:-}" i=0 cur
  while (( i < PANE_RESTART_TRIES )); do
    cur="$(tmuxc display-message -p -t "$pid" '#{pane_current_command}' </dev/null 2>/dev/null || true)"
    case "$cur" in claude|claude.exe) ;; *) return 0 ;; esac
    sleep "$PANE_RESTART_SLEEP"
    i=$((i + 1))
  done
  return 1
}

# ── pinning the restart line to the ACTIVE account (2026-08-16) ──────────────
# Under pool v2 the shared ~/.claude holds NO credential: a session works only
# when it is pinned to its pool dir via CLAUDE_CONFIG_DIR. The restart lines
# below used to send a bare `claude --resume …` and trust PATH to reach the
# ~/.local/bin/claude shim, which pins. On 2026-08-16 pane shells created at
# boot had /opt/homebrew/bin AHEAD of ~/.local/bin, so the bare line ran the
# REAL binary unpinned and five sessions came up dead on "Not logged in ·
# Please run /login". A PATH fix ships separately; THIS is the defence in
# depth: the line a pane is asked to type now carries its own explicit
# CLAUDE_CONFIG_DIR=<active pool dir>, so a restart can never again depend on
# what a pane shell happens to have on PATH.
#
# Resolution is the claim → slot → dir walk the rest of this file already uses
# (json_email + slot_for_email over the loaded accounts), memoised once per
# run, the restart pass after a real switch resolves AFTER the claim moved,
# so every pane pins to the account just switched to. Three outcomes:
#   pin     the active claim maps to a pool dir holding a COMPLETE credential
#           → every restart line is prefixed CLAUDE_CONFIG_DIR=<that dir>
#   bare    no claim/slot resolvable, but the shared ~/.claude credential is
#           complete (a pre-v2 box) → today's bare line still lands live
#   refuse  the resolved dir's credential is a husk, its IDENTITY is not the
#           claim's, it is the shared ~/.claude itself, or nothing resolvable
#           holds a complete credential at all → do NOT restart: /quit-ing a
#           stale-but-alive pane to relaunch onto a dead or WRONG slot trades
#           work for a login prompt, or worse, for a session silently billing
#           another account. Better a stale pane than either.
PANE_PIN_STATE=""   # "" = not resolved yet · pin · bare · refuse
PANE_PIN_DIR=""     # the active account's pool dir ("" when unresolvable)
PANE_PIN_WHY=""     # refuse only: the specific reason, when set (else the generic ones)
pane_pin_resolve() {
  [[ -n "$PANE_PIN_STATE" ]] && return 0
  local email slot found
  email="$(json_email "$HOME/.claude.json")"
  if [[ -n "$email" ]]; then
    slot="$(slot_for_email "$email")"
    if [[ "$slot" != "-1" ]]; then
      PANE_PIN_DIR="${DIRS[$slot]}"
      # ── trust the DIR's identity, not the map's label (2026-08-16) ────────
      # slot_for_email matches the accounts-file LABEL first, and that file is
      # an auto-reconciled cache that can lie (the 2026-08-11 personal/work swap).
      # The line built from this dir is an EXPLICIT CLAUDE_CONFIG_DIR pin, so
      # it bypasses the shim's identity layer entirely, a lying map here
      # would re-pin every restarted pane onto the wrong account, silently.
      # Two refusals before the credential is even considered:
      #   - the dir IS the shared ~/.claude: pinning AT it is the nested-
      #     config trap (the CLI would read ~/.claude/.claude.json), and its
      #     config_email answer comes from ~/.claude.json, the claim itself,
      #     so the identity check below could never catch it;
      #   - the dir's own .claude.json names a DIFFERENT account than the
      #     claim. An empty identity stays acceptable (unknowable, not a lie).
      if [[ "$PANE_PIN_DIR" == "$HOME/.claude" ]] \
         || { [[ -d "$PANE_PIN_DIR" ]] && [[ "$PANE_PIN_DIR" -ef "$HOME/.claude" ]]; }; then
        PANE_PIN_STATE="refuse"
        PANE_PIN_WHY="accounts map sends $email to the shared ~/.claude, pinning AT the shared dir is the nested-config trap; left alone (run: rota reconcile)"
        return 0
      fi
      found="$(config_email "$PANE_PIN_DIR")"
      if [[ -n "$found" && "$found" != "$email" ]]; then
        touch "$CFG_DIR/needs-reconcile" 2>/dev/null || true
        PANE_PIN_STATE="refuse"
        PANE_PIN_WHY="accounts map says $email but $(tilde "$PANE_PIN_DIR") actually holds $found, a pinned restart would silently bill the wrong account; left alone (run: rota reconcile)"
        return 0
      fi
      if cred_is_complete "$PANE_PIN_DIR/.credentials.json"; then
        PANE_PIN_STATE="pin"
      else
        PANE_PIN_STATE="refuse"
      fi
      return 0
    fi
  fi
  # No resolvable pool dir. A pre-v2 box still has a live shared credential
  # and the bare line lands on it; under v2 that file never exists, and a
  # bare restart is a guaranteed "Please run /login" pane.
  if cred_is_complete "$HOME/.claude/.credentials.json"; then
    PANE_PIN_STATE="bare"
  else
    PANE_PIN_STATE="refuse"
  fi
  return 0
}

# What a restarted pane is asked to resume: the SESSION ID behind its title, or
# the title itself when nothing resolves. A title is only unique by luck
# (sessions get renamed to their predecessor's title, the morning's and the
# afternoon's "project x"), and `claude --resume "<title>"` on a non-unique
# title parks the pane in a session picker nobody is watching: three of four
# restarted panes stalled there on 2026-09-02. The id is exact.
#
# The pane's session is the NEWEST transcript whose CURRENT title (the last
# custom-title line; an earlier one may be a title since renamed away) is
# exactly the pane's. Only recently modified transcripts are candidates (a
# live pane writes its file every turn), only top-level ones (subdirs are
# sidecar data), and a cheap grep for the encoded title runs before any jq,
# because the projects dir is gigabytes and a restart must not read all of
# it. A malformed line is skipped, never fatal (fromjson?). Callers resolve
# ONCE per pane, so the reported id is the sent one.
pane_resume_target() {  # pane_resume_target <title> → <session-id>, or <title> when nothing resolves
  local title="${1:-}" needle f cur id mt best="" best_mt=-1
  local uuid_re='^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
  if [[ -z "$title" || ! -d "$PROJECTS_DIR" ]]; then printf '%s' "$title"; return 0; fi
  # the fragment as the transcript spells it: JSON-encoded, so a title holding
  # a quote or a backslash is looked for as its escaped bytes, not its raw ones
  needle="\"customTitle\":$(jq -cn --arg t "$title" '$t' 2>/dev/null)" || needle=""
  if [[ -z "$needle" ]]; then printf '%s' "$title"; return 0; fi
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    id="${f##*/}"; id="${id%.jsonl}"
    [[ "$id" =~ $uuid_re ]] || continue
    cur="$(grep -aF '"custom-title"' "$f" 2>/dev/null \
      | jq -Rr 'fromjson? | select(.type == "custom-title") | .customTitle // empty' 2>/dev/null \
      | tail -1)" || cur=""
    [[ "$cur" == "$title" ]] || continue
    mt="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)" || mt=0
    [[ "$mt" =~ ^[0-9]+$ ]] || mt=0
    if (( mt > best_mt )); then best="$id"; best_mt="$mt"; fi
  done < <(find "$PROJECTS_DIR" -mindepth 2 -maxdepth 2 -name '*.jsonl' -mtime -3 \
             -exec grep -alF -- "$needle" {} + 2>/dev/null || true)
  printf '%s' "${best:-$title}"
}

# The exact line a restarted pane is asked to type. ONE builder, shared by the
# senders and every would-restart/restarted report line, so what is printed is
# by construction what is sent. The target is what pane_resume_target
# resolved, never a raw pane title.
pane_resume_line() {  # pane_resume_line <resume-target>
  pane_pin_resolve
  if [[ "$PANE_PIN_STATE" == "pin" ]]; then
    printf 'CLAUDE_CONFIG_DIR=%s claude --resume %s' \
      "$(dq_arg "$PANE_PIN_DIR")" "$(dq_arg "${1:-}")"
  else
    printf 'claude --resume %s' "$(dq_arg "${1:-}")"
  fi
}

# The one loud sentence for the refuse state, shared by every caller, it must
# name the exact fix, because the only way out of a husk (or a lying map) is a
# human. A specific reason from pane_pin_resolve (identity mismatch, shared-dir
# trap, 2026-08-16) wins over the generic husk/nothing-resolvable pair.
pane_pin_refuse_reason() {
  if [[ -n "$PANE_PIN_WHY" ]]; then
    printf '%s' "$PANE_PIN_WHY"
  elif [[ -n "$PANE_PIN_DIR" ]]; then
    printf 'active account credential is a husk, restart would land on a dead slot; left alone (login needed: CLAUDE_CONFIG_DIR=%s claude)' \
      "$(tilde "$PANE_PIN_DIR")"
  else
    printf 'no resolvable account holds a complete credential, restart would land on a dead slot; left alone (see: rota usage)'
  fi
}

# The one restart sequence, shared by restart_idle_panes and pane-converge so
# the mechanism can never fork: /quit, wait for the shell (bounded, a pane
# that never lets go is LEFT ALONE, never force-killed), then resume the
# TARGET the caller resolved through pane_resume_target (the session id, or
# the title when nothing resolves), explicitly pinned to the active account's
# pool dir (pane_pin_resolve above, 2026-08-16). Returns 0 restarted · 1 the
# /quit send failed (pane gone?) · 2 still running claude after /quit · 3
# /quit landed but the resume line did not · 4 REFUSED before touching the
# pane: the active account's credential is a husk/absent, so a restart could
# only produce a dead "/login" pane.
pane_restart_one() {  # pane_restart_one <pane-id> <resume-target>
  local pid="${1:-}" target="${2:-}"
  pane_pin_resolve
  [[ "$PANE_PIN_STATE" == "refuse" ]] && return 4
  tmuxc send-keys -t "$pid" '/quit' Enter </dev/null 2>/dev/null || return 1
  pane_await_shell "$pid" || return 2
  tmuxc send-keys -t "$pid" "$(pane_resume_line "$target")" Enter </dev/null 2>/dev/null || return 3
  return 0
}

# Restart the panes that are safe to restart, so they ADOPT the account we just
# switched to. THE DEFAULT since 2026-08-12 (--new-only opts out; --restart-idle
# remains as the explicit spelling); it was opt-in before, and the rules below
# are the expensive ones, each was paid for once already:
#
#   • A pane that is mid-work is SKIPPED. Killing a pane during a tool call
#     destroys that work; no amount of "it was probably fine" is worth it.
#     (pane-converge picks those up once they go idle.)
#   • `claude --resume "<session-id>"`, the id resolved from the pane title
#     (pane_resume_target), the bare title only when nothing resolves; NEVER
#     `claude --continue`. --continue resumes the most recent conversation
#     FOR THE WORKING DIRECTORY, and every pane here sits in ~/code, so it
#     loads some other pane's conversation. Done once, on 2026-08-06. And a
#     title is not an id: sessions get renamed to their predecessor's title,
#     and resuming a non-unique title parks the pane in a session picker
#     nobody is watching. Three of four restarted panes stalled there on
#     2026-09-02.
#   • A pane whose title reads back EMPTY is SKIPPED and reported, because
#     `claude --resume ""` drops the pane to a bare shell. Also done once.
#   • The pane running this command is never restarted (it would kill the
#     switch mid-flight).
restart_idle_panes() {  # restart_idle_panes <dry-run 0|1> [<explicit 0|1>]
  local dry="${1:-0}" explicit="${2:-0}"
  if ! panes_scan; then
    # Silent when the restart is only the DEFAULT riding along with a switch:
    # a laptop has no such session and must not be nagged about it on
    # every switch. An EXPLICIT --restart-idle still gets the reason, and the
    # reason DISTINGUISHES binary-not-found / server-unreachable / no-such
    # -session (keeper polish, 2026-08-12): "no session" from a launchd context
    # used to mean "could not even look", and reading it as "nothing to do"
    # hid a real reachability bug for a whole morning.
    (( explicit )) || return 0
    printf '  %s\n' "$(paint "$CLR_DIM" \
      "--restart-idle: ${PANES_UNAVAIL_REASON:-no '$PANES_SESSION' tmux session here}, nothing to restart")"
    return 0
  fi
  local self="${TMUX_PANE:-}"
  echo
  printf '  %s%s\n' "$(paint "$CLR_BOLD" 'RESTART IDLE')" \
    "$(paint "$CLR_DIM" "$( (( dry )) \
        && printf ', dry run: listing what WOULD be restarted, sending nothing' \
        || printf ', idle panes restarted (default; --new-only to skip): /quit, then claude --resume "<session-id>", per pane')")"
  # The row's 4th field (may-be-on-the-previous-account) is read and DELIBERATELY
  # not used as a filter: right after a real switch the credential changed a
  # second ago, so every pane predates it and the flag would select all of them
  # anyway, while on a --dry-run it would select a different, smaller set, and a
  # dry run that lists fewer panes than the real run would then perform is worse
  # than useless. The rule stays the simple one: restart every idle pane.
  local pid title working prev tty name target
  # shellcheck disable=SC2034  # `prev`/`tty` are read positionally; see above
  while IFS="$PANES_US" read -r pid title working prev tty; do
    [[ -n "$pid" ]] || continue
    if [[ -n "$self" && "$pid" == "$self" ]]; then
      printf '         %-5s %s\n' "$pid" "skipped, this is the pane running the switch"
      continue
    fi
    if [[ "$working" == "1" ]]; then
      printf '         %-5s %s\n' "$pid" "skipped, mid-work (restarting it would destroy the work in flight)"
      continue
    fi
    name="$(strip_pane_glyph "$title")"
    if [[ -z "$name" ]]; then
      printf '         %-5s %s\n' "$pid" "skipped, empty pane title, so there is no session name to resume"
      continue
    fi
    # resolved once: the plan, the sent line and the result line all show it
    target="$(pane_resume_target "$name")"
    if (( dry )); then
      # The dry run must tell the truth about BOTH halves of the 2026-08-16
      # hardening: the pinned line it would send, and the refusal it would
      # make instead when the active credential is a husk.
      pane_pin_resolve
      if [[ "$PANE_PIN_STATE" == "refuse" ]]; then
        printf '         %-5s %s\n' "$pid" "would skip, $(pane_pin_refuse_reason)"
      else
        printf '         %-5s %s\n' "$pid" "would restart → $(pane_resume_line "$target")"
      fi
      continue
    fi
    local rrc=0
    pane_restart_one "$pid" "$target" || rrc=$?
    case "$rrc" in
      0) printf '         %-5s %s\n' "$pid" "restarted → $(pane_resume_line "$target")" ;;
      1) printf '         %-5s %s\n' "$pid" "skipped, send-keys failed (pane gone?)" ;;
      2) printf '         %-5s %s\n' "$pid" "skipped, still running claude after /quit; left alone" ;;
      4) printf '         %-5s %s\n' "$pid" "skipped, $(pane_pin_refuse_reason)" ;;
      *) printf '         %-5s %s\n' "$pid" "FAILED, /quit sent but the resume line did not; pane is at a shell" ;;
    esac
  done <<<"$PANES_ROWS"
  return 0
}

# ── pane-converge: busy panes catch up with the switch once they go idle ─────
# The operator's requirement (2026-08-12): after a switch, EVERY pane must end up on
# the active account without further action, idle panes immediately (the
# switch's default restart), and mid-work panes as soon as they finish. Before
# this, a pane that happened to be busy during the switch stayed pinned to the
# old account FOREVER. This verb is the retry: it finds panes whose claude
# process is pinned (CLAUDE_CONFIG_DIR, via the same `ps eww` walk the
# `billing now:` header uses) to a POOL dir whose identity differs from the
# active claim, and restarts the idle ones through the exact machinery
# restart_idle_panes uses, same mid-work skip, same /quit + resume by the
# session id pane_resume_target puts behind the title.
# The keeper runs it every tick (step 4b), so "converges when idle" is
# minutes, not "whenever someone remembers".
#
# UNPINNED panes count as DIVERGENT too (2026-08-16). This verb used to skip a
# claude with NO CLAUDE_CONFIG_DIR at all as "identity unknowable", which made
# the day's actual failure mode invisible to it: five sessions launched at boot
# through a PATH that bypassed the shim ran the real binary unpinned against
# the credential-less shared ~/.claude, sat dead on "Please run /login", and
# converge, the tool whose whole job is putting panes back on the active
# account, reported nothing to do, forever. Under pool v2 an unpinned claude
# cannot be on ANY account, which is as divergent from the claim as a stale pin
# so it now goes through the same restart machinery (same mid-work skip, and
# pane_restart_one's own husk refusal still guards the relaunch). Non-pool pins
# stay untouched: those are deliberate, an absent pin never is.

# The CLAUDE_CONFIG_DIR of the claude process on a pane's tty, from the same
# pool_ps output live_claude_pins reads ("" when there is no claude process on
# that tty, or it carries no pin, an unpinned pre-shim session). The TT column
# of `ps eww -ax` prints ttys003 as s003, so both spellings are matched.
pane_pin_dir() {  # pane_pin_dir <pane-tty, e.g. /dev/ttys003>
  local tty="${1:-}" short
  [[ -n "$tty" ]] || return 0
  short="${tty#/dev/}"
  pool_ps | awk -v t1="$short" -v t2="${short#tty}" '
    NR == 1 && $1 == "PID" { next }
    $2 == t1 || $2 == t2 {
      cmd = $5; sub(".*/", "", cmd)
      if (cmd != "claude" && cmd != "claude.exe") next
      for (i = 6; i <= NF; i++)
        if ($i ~ /^CLAUDE_CONFIG_DIR=/) {
          sub("CLAUDE_CONFIG_DIR=", "", $i)
          print $i; exit
        }
    }' 2>/dev/null || true
}

# Is this pinned dir a POOL dir, one this tool is allowed to reason about?
# A pin to the shared ~/.claude is not (that is the pointer slot, not an
# account), and neither is a scratch/login-capture dir outside both the
# canonical ~/.claude-pool/ home and the accounts-file roster: converge must
# NEVER touch a pane someone deliberately pinned somewhere unusual.
pane_dir_is_pool() {  # pane_dir_is_pool <dir>
  local dir="${1:-}" d
  [[ -n "$dir" ]] || return 1
  [[ "$dir" == "$HOME/.claude" ]] && return 1
  [[ -d "$dir" && "$dir" -ef "$HOME/.claude" ]] && return 1
  case "$dir" in "$HOME/.claude-pool/"*) return 0 ;; esac
  for d in "${DIRS[@]}"; do
    [[ "$dir" == "$d" ]] && return 0
    [[ -d "$dir" && -d "$d" && "$dir" -ef "$d" ]] && return 0
  done
  return 1
}

cmd_pane_converge() {  # cmd_pane_converge [--dry-run]
  local dry=0 a
  for a in "$@"; do
    case "$a" in
      --dry-run|-n) dry=1 ;;
      *) die "usage: rota failover pane-converge [--dry-run]" ;;
    esac
  done
  local claim; claim="$(json_email "$HOME/.claude.json")"
  if [[ -z "$claim" ]]; then
    printf 'pane-converge: no active claim in ~/.claude.json, nothing to converge toward\n'
    printf 'pane-converge: restarted=0 busy=0 divergent=0\n'
    return 0
  fi
  if ! panes_scan; then
    # this verb IS the explicit ask, so the reason prints (same three-way
    # diagnosis restart_idle_panes gives an explicit --restart-idle)
    printf 'pane-converge: %s, nothing to converge\n' \
      "${PANES_UNAVAIL_REASON:-no '$PANES_SESSION' tmux session here}"
    printf 'pane-converge: restarted=0 busy=0 divergent=0\n'
    return 0
  fi
  local self="${TMUX_PANE:-}" restarted=0 busy=0 divergent=0
  local pid title working prev tty dir id name target rrc
  # shellcheck disable=SC2034  # `prev` is read positionally to reach `tty`
  while IFS="$PANES_US" read -r pid title working prev tty; do
    [[ -n "$pid" ]] || continue
    dir="$(pane_pin_dir "$tty")"
    if [[ -n "$dir" ]]; then
      pane_dir_is_pool "$dir" || continue  # non-pool pin (scratch/login capture) → never touched
      id="$(config_email "$dir")"
      [[ -n "$id" ]] || continue           # dir has no identity → nothing to compare
      [[ "$id" == "$claim" ]] && continue  # already on the active account
    else
      # no pin at all → divergent BY DEFINITION under pool v2 (2026-08-16,
      # see the section comment: unpinned panes were the broken ones, and the
      # old `continue` here is what kept them broken). EXCEPT on a pre-v2 box
      # (pane_pin state `bare`: no resolvable claim, shared ~/.claude holds a
      # live credential): there an unpinned pane IS on the right account, and
      # a bare restart comes back unpinned, restarting it every tick would be
      # a /quit loop that never converges anything.
      pane_pin_resolve
      [[ "$PANE_PIN_STATE" == "bare" ]] && continue
      id="unpinned, no CLAUDE_CONFIG_DIR"
    fi
    divergent=$((divergent + 1))
    if [[ -n "$self" && "$pid" == "$self" ]]; then
      printf '%s still on %s, this is the pane running the converge; left alone\n' "$pid" "$id"
      busy=$((busy + 1))
      continue
    fi
    if [[ "$working" == "1" ]]; then
      printf '%s busy on %s, mid-work is never restarted; converges when idle\n' "$pid" "$id"
      busy=$((busy + 1))
      continue
    fi
    name="$(strip_pane_glyph "$title")"
    if [[ -z "$name" ]]; then
      printf '%s still on %s, empty pane title, no session name to resume; left alone\n' "$pid" "$id"
      busy=$((busy + 1))
      continue
    fi
    target="$(pane_resume_target "$name")"  # once: plan, sent line and result agree
    if (( dry )); then
      pane_pin_resolve
      if [[ "$PANE_PIN_STATE" == "refuse" ]]; then
        printf '%s on %s → would NOT restart, %s\n' "$pid" "$id" "$(pane_pin_refuse_reason)"
        busy=$((busy + 1))
      else
        printf '%s on %s → would restart (%s)\n' "$pid" "$id" "$(pane_resume_line "$target")"
        restarted=$((restarted + 1))
      fi
      continue
    fi
    rrc=0
    pane_restart_one "$pid" "$target" || rrc=$?
    if (( rrc == 0 )); then
      printf '%s restarted onto %s (was %s) → %s\n' "$pid" "$claim" "$id" "$(pane_resume_line "$target")"
      restarted=$((restarted + 1))
    elif (( rrc == 4 )); then
      # husk refusal (2026-08-16): a stale pane beats a guaranteed-dead one
      printf '%s still on %s, %s\n' "$pid" "$id" "$(pane_pin_refuse_reason)"
      busy=$((busy + 1))
    else
      printf '%s still on %s, restart did not land (rc=%s); will retry next tick\n' "$pid" "$id" "$rrc"
      busy=$((busy + 1))
    fi
  done <<<"$PANES_ROWS"
  printf 'pane-converge: restarted=%d busy=%d divergent=%d claim=%s%s\n' \
    "$restarted" "$busy" "$divergent" "$claim" "$( (( dry )) && printf ' (dry-run)' )"
  return 0
}

render_usage() {
  render_usage_table
  render_recommendation
  render_panes_summary
}

# Same data, machine-readable, so a future consumer never has to parse columns.
json_usage() {
  local i rows="" wk se wk_used se_used wk_fresh se_fresh
  local wk_in se_in logged_in is_live is_stale
  for i in "${!DIRS[@]}"; do
    wk="null"; se="null"; wk_used="null"; se_used="null"
    # `fresh` is what lets a consumer tell the two null-resets_at cases apart without
    # guessing: fresh=true is "100% left, the window has not started" (remaining_pct
    # is 100, used_pct 0), fresh=false with a null resets_at and null percentages is
    # "we do not know". Additive, nothing existing is renamed or removed.
    wk_fresh=false; se_fresh=false
    window_fresh "${U_WKU[$i]}" "${U_WKR[$i]}" "${U_WKX[$i]}" && wk_fresh=true
    window_fresh "${U_SEU[$i]}" "${U_SER[$i]}" "${U_SEX[$i]}" && se_fresh=true
    # used_pct is ADDITIVE alongside the long-published remaining_pct, same
    # null-gating (expired or unparseable windows stay null in both), so a consumer
    # can read either polarity without inverting the other by hand. Field ORDER and
    # NAMES here are deliberately untouched by the used-first change: only the
    # RENDERED order leads with used. See the polarity note above remaining().
    #
    # weekly.kind / weekly.scope are likewise additive: which `limits` entry produced
    # weekly's numbers, and the model it is scoped to. Both null when the response had
    # no usable `limits` array (seven_day fallback) or the binding limit is unscoped,
    # so a consumer can tell an all-model weekly figure from a per-model cap.
    #
    # weekly.resets_at_projected / weekly.projected_from, additive (2026-09-04), are
    # the SEPARATE pair project_weekly fills: the reset this seat will see next when
    # the vendor named none (an untouched window), and the seen instant it was rolled
    # forward from. resets_at and resetsInSeconds stay measurement-only, so a consumer
    # that ignores the new keys cannot end up treating an inference as an API answer -
    # a consumer that wants the best available instant reads `resets_at //
    # resets_at_projected` and renders it with the `~` the tables use.
    [[ -n "$(remaining "${U_WKU[$i]}")" ]] && (( U_WKX[i] == 0 )) \
      && { wk="$(remaining "${U_WKU[$i]}")"; wk_used="$(used "${U_WKU[$i]}")"; }
    [[ -n "$(remaining "${U_SEU[$i]}")" ]] && (( U_SEX[i] == 0 )) \
      && { se="$(remaining "${U_SEU[$i]}")"; se_used="$(used "${U_SEU[$i]}")"; }
    # ── the camelCase view, ADDITIVE (2026-08-06) ────────────────────────────
    # A phone renderer needs three things this object did not carry: whether the
    # account can be switched to at all (loggedIn, the same rule `status` prints,
    # via slot_logged_in), whether the row it is showing was fetched this run
    # (live/stale, the same test switch-auto now scores on, via usage_row_stale),
    # and a countdown it does not have to parse out of an ISO string
    # (resetsInSeconds). Nothing above is renamed: `active`, `data`,
    # `remaining_pct`, `five_hour` and the rest keep their published names and
    # order, and the camelCase keys sit alongside them. `current` is an alias of
    # `active`, matching what the dashboard's account endpoint already calls it; `session`
    # is an alias of `five_hour` under the name the phone UI uses.
    wk_in="$(iso_in_seconds "${U_WKR[$i]}")"; [[ -n "$wk_in" ]] || wk_in="null"
    se_in="$(iso_in_seconds "${U_SER[$i]}")"; [[ -n "$se_in" ]] || se_in="null"
    # ── provenance, ADDITIVE (2026-08-27) ────────────────────────────────────
    # Three fields, one question: how much should a consumer trust this number?
    #   quota_data         live | cached | peer | none | dup, the same word `data`
    #                      has always carried, under the name rota-billing.sh
    #                      publishes it as, so ONE vocabulary spans both surfaces
    #                      and a peer parser does not have to care which answered
    #   quota_source       the peer host these numbers were read from, null when
    #                      this box measured them itself
    #   quota_measured_at  when the numbers were MEASURED, not when the object was
    #                      generated. The two differ by days on a seat nothing runs
    #                      sessions on, and a machine consumer deserves the same
    #                      honesty the table gets, see age_short.
    # ── the seat's lifecycle, ADDITIVE (2026-08-25) ─────────────────────────
    # A consumer that only ever saw `weekly.expired` could not tell "finished"
    # from "unmeasured" either, and the dashboard reads this object.
    # `unmeasured` is the state the table now calls UNMEASURED; `seat.ended` is
    # the only field that means the account is actually done.
    local seat_status seat_ends seat_done unmeasured
    seat_status="$(seat_field "${U_EMAIL[$i]}" 1)"; : "${seat_status:=active}"
    seat_ends="$(seat_ends_on "$i")"
    seat_done=false; seat_ended "$i" && seat_done=true
    unmeasured=false
    if [[ "$seat_done" == false ]] && weekly_unknown "$i" && [[ "${U_STATE[$i]}" != "dup" ]]; then
      unmeasured=true
    fi
    logged_in=false; slot_logged_in "$i" && logged_in=true
    is_live=false; [[ "${U_STATE[$i]}" == "live" ]] && is_live=true
    is_stale=false; usage_row_stale "$i" && is_stale=true
    rows="$rows$(jq -cn \
      --argjson wk_in "$wk_in" --argjson se_in "$se_in" \
      --argjson logged_in "$logged_in" --argjson is_live "$is_live" \
      --argjson is_stale "$is_stale" \
      --argjson seat_done "$seat_done" --argjson unmeasured "$unmeasured" \
      --arg seat_status "$seat_status" --arg seat_ends "$seat_ends" \
      --arg label "${LABELS[$i]}" \
      --arg email "${U_EMAIL[$i]}" \
      --arg dir "${DIRS[$i]}" \
      --arg alias "$(basename "${DIRS[$i]}")" \
      --arg state "${U_STATE[$i]}" \
      --arg wk_reset "${U_WKR[$i]}" \
      --arg wk_proj "${U_WKP[$i]:-}" \
      --arg wk_proj_from "${U_WKPF[$i]:-}" \
      --arg se_reset "${U_SER[$i]}" \
      --arg wk_kind "${U_WKK[$i]}" \
      --arg wk_scope "${U_WKS[$i]}" \
      --arg cached_at "${U_TS[$i]}" \
      --arg src "${U_SRC[$i]:-}" \
      --arg meas "${U_MEAS[$i]:-}" \
      --arg why "${U_WHY[$i]}" \
      --arg via "${U_VIA[$i]}" \
      --arg reason "${U_REASON[$i]}" \
      --argjson wk "$wk" --argjson se "$se" \
      --argjson wk_used "$wk_used" --argjson se_used "$se_used" \
      --argjson wk_exp "${U_WKX[$i]}" --argjson se_exp "${U_SEX[$i]}" \
      --argjson wk_fresh "$wk_fresh" --argjson se_fresh "$se_fresh" \
      --argjson active "$( (( i == SHARED_SLOT )) && echo true || echo false )" \
      --argjson rec "$( (( U_REC[i] == 1 )) && echo true || echo false )" \
      '{label:$label, email:$email, config_dir:$dir, alias:$alias, active:$active,
        current:$active, loggedIn:$logged_in, live:$is_live, stale:$is_stale,
        unmeasured:$unmeasured,
        seat:{status:$seat_status, ends:(if $seat_ends=="" then null else $seat_ends end),
              ended:$seat_done},
        data:$state, cached_at:(if $cached_at=="" then null else $cached_at end),
        quota_data:$state,
        quota_source:(if $src=="" then null else $src end),
        quota_measured_at:(if $meas=="" then null else $meas end),
        weekly:{remaining_pct:$wk, used_pct:$wk_used, resets_at:(if $wk_reset=="" then null else $wk_reset end), expired:($wk_exp==1), fresh:$wk_fresh,
                kind:(if $wk_kind=="" then null else $wk_kind end),
                scope:(if $wk_scope=="" then null else $wk_scope end),
                leftPct:$wk, usedPct:$wk_used,
                resetsAt:(if $wk_reset=="" then null else $wk_reset end),
                resetsInSeconds:$wk_in,
                resets_at_projected:(if $wk_proj=="" then null else $wk_proj end),
                projected_from:(if $wk_proj_from=="" then null else $wk_proj_from end)},
        five_hour:{remaining_pct:$se, used_pct:$se_used, resets_at:(if $se_reset=="" then null else $se_reset end), expired:($se_exp==1), fresh:$se_fresh},
        session:{leftPct:$se, usedPct:$se_used,
                 resetsAt:(if $se_reset=="" then null else $se_reset end),
                 resetsInSeconds:$se_in, expired:($se_exp==1), fresh:$se_fresh},
        note:(if $via=="" then null else $via end),
        stale_reason:(if $why=="" then null else $why end),
        recommendable:$rec,
        reason:(if $reason=="" then null else $reason end)}')"$'\n'
  done
  # ⚠️ THE DATE THE RECOMMENDATION PUBLISHES IS THE DEADLINE, min(weekly reset,
  # SEAT END), NOT THE WEEKLY RESET. It was published as `weekly_resets_at` from
  # 2026-08-27 (when the ranking moved to the deadline) until 2026-08-28, which
  # meant that on a cancelled seat whose end date falls before its next reset the
  # key named one thing and carried another: `tartare@codeandstate.com` resets
  # 3 Sep and ends 1 Sep, so a pick bound by that seat published 1 Sep under a key
  # promising a weekly reset. Right value, wrong noun, on the MACHINE surface -
  # the exact defect rota#9 had just fixed on the human one (recommendation_text
  # said "soonest weekly reset" when the seat end had bound the choice).
  #
  # So the key is `deadline_at` and it is published WITH `deadline_kind`. The kind
  # is not decoration: a bare instant cannot say which of the two things it is, and
  # that ambiguity IS the defect - renaming without it would move the problem
  # rather than end it. Its values are `reset` and `seat-end` verbatim out of
  # rota_seat_deadline (rota-ranking.sh), never re-spelled here, so the published
  # noun and the rule that chose it can never drift apart; kebab also matches the
  # only other multi-word enum on this same object, `mode: "burn-down"`.
  #
  # The rename was outright rather than additive because a grep of the whole fleet
  # on 2026-08-28 found `recommendation.weekly_resets_at` read in exactly two
  # places, both this repo's own tests, so a parallel field or a deprecation window
  # would have been ceremony for an audience of zero. What made it SAFE is the
  # schema lock in tests/engine.test.sh (EX_JSON_PATHS_WANT): the rename cannot
  # land silently, it reds that assertion until the published contract is edited
  # by hand. Do NOT extend this rename to `weekly_resets_at` elsewhere - on
  # `cdt billing --json`'s per-account rows, and on this file's own
  # `accounts[].weekly.resets_at`, that name is correct and load-bearing.
  #
  # ⚠️ AND `deadline_projected` BESIDE THEM, for the same reason the kind is
  # there: a bare instant cannot say whether the vendor reported it or this box
  # inferred it from the seat's cadence, and `deadline_at` can now be either.
  # The human surfaces mark the difference with `~`; a parser gets the boolean.
  local action="none" rec_email="null" rec_alias="null" rec_label="null"
  local rec_deadline="null" rec_deadline_kind="null"
  local rec_fresh=false
  (( REC_FRESH )) && rec_fresh=true
  if (( REC_SLOT >= 0 )); then
    if (( REC_SLOT == SHARED_SLOT )); then action="stay"; else action="switch"; fi
    rec_email="$(jq -n --arg v "$REC_EMAIL" '$v')"
    rec_alias="$(jq -n --arg v "$(basename "${DIRS[$REC_SLOT]}")" '$v')"
    rec_label="$(jq -n --arg v "${LABELS[$REC_SLOT]}" '$v')"
    # a FRESH pick has no deadline instant, null, matching the windows' own resets_at,
    # rather than the empty string that would read as a malformed timestamp. The KIND
    # goes null with it, and that pairing is the point: a kind beside no date would be
    # a claim about a deadline that does not exist. rota_seat_deadline returns both
    # fields empty for a seat with neither date, so null/null mirrors its answer.
    [[ -n "$REC_RESET" ]] && rec_deadline="$(jq -n --arg v "$REC_RESET" '$v')"
    [[ -n "$REC_DEADLINE_KIND" ]] && rec_deadline_kind="$(jq -n --arg v "$REC_DEADLINE_KIND" '$v')"
  fi
  # The recommendation's own words, taken from the function the human dashboard
  # prints, not paraphrased here, or the phone and the terminal would start giving
  # different explanations of the same pick. The rendered form is at most two lines
  # (the `rota switch <alias>` line plus its rationale); collapse them into the one
  # line a JSON consumer wants. Never empty: recommendation_text always prints one
  # of its four sentences, including the "nothing to recommend" one.
  local rec_reason
  rec_reason="$(recommendation_text | tr '\n' ' ' | sed 's/  */ /g; s/ *$//')"
  printf '%s' "$rows" | jq -s \
    --arg gen "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg active "$SHARED_EMAIL" \
    --arg source "$SHARED_SOURCE" \
    --arg warn "$SHARED_WARN" \
    --arg fp "$SHARED_FP" \
    --arg auth "$SHARED_AUTH" \
    --arg auth_warn "$AUTH_WARN" \
    --arg nested_warn "$NESTED_WARN" \
    --arg peer_host "$PEER_HOST" \
    --arg peer_gen "$PEER_GENERATED" \
    --arg action "$action" \
    --arg rec_reason "$rec_reason" \
    --argjson rec_email "$rec_email" --argjson rec_alias "$rec_alias" \
    --argjson rec_label "$rec_label" --argjson rec_deadline "$rec_deadline" \
    --argjson rec_deadline_kind "$rec_deadline_kind" \
    --argjson rec_projected "$( (( REC_PROJECTED )) && echo true || echo false )" \
    --argjson rec_fresh "$rec_fresh" \
    --argjson rec_cached "$( (( REC_CACHED )) && echo true || echo false )" \
    --argjson rec_hold "$( (( REC_HOLD )) && echo true || echo false )" \
    --arg mode "$REC_MODE" \
    --argjson mode_forced "$( (( REC_MODE_FORCED )) && echo true || echo false )" \
    --arg alt_email "$BEST_ALT_EMAIL" \
    --argjson alt_pct "${BEST_ALT_PCT:-null}" \
    --argjson min_weekly "$MIN_WEEKLY" --argjson min_session "$MIN_SESSION" \
    --argjson exhausted "$EXHAUSTED_PCT" --argjson comfortable "$COMFORTABLE_PCT" \
    '{generated_at:$gen,
      generatedAt:$gen,
      active:{email:(if $active=="" then null else $active end),
              source:(if $source=="" then null else $source end),
              fingerprint:(if $fp=="" then null else $fp end),
              auth_status:(if $auth=="" then null else $auth end),
              warning:(if $warn=="" then null else $warn end),
              auth_warning:(if $auth_warn=="" then null else $auth_warn end),
              nested_config_warning:(if $nested_warn=="" then null else $nested_warn end)},
      activeEmail:(if $active=="" then null else $active end),
      floors:{weekly_pct:$min_weekly, session_pct:$min_session,
              exhausted_pct:$exhausted, comfortable_pct:$comfortable},
      peer:(if $peer_host=="" then null
            else {host:$peer_host,
                  generated_at:(if $peer_gen=="" then null else $peer_gen end)} end),
      accounts:.,
      recommendation:{action:$action, email:$rec_email, label:$rec_label,
                      alias:$rec_alias,
                      deadline_at:$rec_deadline, deadline_kind:$rec_deadline_kind,
                      deadline_projected:$rec_projected,
                      weekly_fresh:$rec_fresh,
                      from_cached_numbers:$rec_cached,
                      mode:$mode, mode_forced:$mode_forced,
                      best_alternative:{email:(if $alt_email=="" then null else $alt_email end),
                                        weekly_left_pct:$alt_pct},
                      burn_down_hold:$rec_hold,
                      reason:$rec_reason}}'
}

main() {
  local sub="${1:-}"
  # help needs no config. The Usage block is pulled straight out of this script's
  # header so it can never drift from it (the old fixed line range did, silently
  # truncating the verb list part-way through).
  case "$sub" in
    -h|--help|help)
      sed -n '/^# Usage:/,/^[^#]/p' "$0" | sed '/^[^#]/d; s/^# \{0,1\}//'
      printf '\nDesign notes + incident history: the comment header of %s\n' "$0"
      return 0 ;;
    # repair-nested needs no config either, and deliberately runs BEFORE
    # load_accounts: the nested-config trap is a property of ~/.claude, not of the
    # account pool, so a box that has never had an accounts file (the likeliest place
    # to hit the trap) must still be able to fix it.
    repair-nested)
      shift || true
      local rc=0
      repair_nested_config "$@" || rc=$?
      return "$rc" ;;
    # pool-init and roster do their own accounts-file check: with no file they
    # must print the how-to and exit 2 (a fresh box's most likely state), not
    # load_accounts' generic die.
    pool-init)
      shift || true
      cmd_pool_init "$@"
      return 0 ;;
    # roster prints the accounts file as the keeper consumes it: one "email|dir"
    # per line, comments and blank lines stripped, read-only. The pool keeper's
    # displaced-login detection uses it to resolve which pool dir an account
    # belongs to.
    roster)
      if [[ ! -f "$ACCOUNTS_FILE" ]]; then
        accounts_file_missing_guidance
        exit 2
      fi
      load_accounts
      local ri
      for ri in "${!LABELS[@]}"; do
        printf '%s|%s\n' "${LABELS[$ri]}" "${DIRS[$ri]}"
      done
      return 0 ;;
  esac
  # Arm the JSON error shape BEFORE load_accounts, so a missing accounts file (the
  # most likely failure on a box that has never been set up) still answers a --json
  # caller with a parseable {"error":…} rather than an English line on stderr.
  case "$sub" in
    usage|accounts)
      local a
      for a in "$@"; do [[ "$a" == "--json" ]] && { JSON_MODE=1; break; }; done
      ;;
  esac
  load_accounts
  case "$sub" in
    next)
      shift || true
      local i; i="$(current_index)"
      local nxt=$(( (i + 1) % ${#DIRS[@]} ))
      launch "$nxt" --continue "$@"
      ;;
    reset)
      set_index 0; echo "reset to account 1 (${LABELS[0]})" ;;
    here)
      local i; i="$(current_index)"; echo "${DIRS[$i]}" ;;
    active)
      # `status`'s `*` marks the LAUNCH slot (STATE_FILE), which switch-all
      # never touches, the account that actually governs is whatever
      # credential sits in the shared ~/.claude. This prints exactly that:
      # the email, one line, nothing else, or nothing + exit 3 when it
      # can't be known, so callers can tell "unknown" apart from die()'s exit 1.
      # Identity is ~/.claude.json's oauthAccount (with the usage fingerprint as
      # the fallback), cross-checked against pool credential bytes. --auto stays
      # subprocess-free, the dashboard polls this, so the `claude auth status` third
      # opinion is left to `usage`'s --verify. See the header block.
      resolve_shared_identity --auto
      [[ -n "$SHARED_WARN" ]] && printf '%s\n' "$SHARED_WARN" >&2
      [[ -n "$SHARED_EMAIL" ]] || exit 3
      printf '%s\n' "$SHARED_EMAIL"
      ;;
    usage|accounts)
      # `usage` is the primary name ("how much do I have left" is the question
      # actually being asked); `accounts` stays a permanent alias.
      shift || true
      local as_json=0
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --no-refresh|-n) NET=0 ;;
          --refresh|-r)    NET=1 ;;   # accepted no-op: refreshing IS the default now
          --json)          as_json=1 ;;
          --verbose|-v)    VERBOSE=1 ;;
          --color)         COLOR_MODE=always ;;
          --no-color)      COLOR_MODE=never ;;
          # `--record` writes and returns; it never falls through to the report,
          # because the report it would print is the one made stale by the very
          # number just typed in.
          --record)        shift; command -v jq >/dev/null 2>&1 || die "usage --record needs jq"
                           record_human_usage "${1:-}" "${2:-}" "${3:-}" "${4:-}"; return 0 ;;
          *) die "usage: rota failover usage [--no-refresh] [--json] [--verbose] [--color|--no-color]
       rota failover usage --record <alias> <weekly-used-%> [<5h-used-%>] [<weekly-reset-iso>]" ;;
        esac
        shift
      done
      command -v jq >/dev/null 2>&1 || die "usage needs jq"
      # --json is a machine surface: never colour it, whatever stdout is
      if (( as_json )); then COLOR_MODE=never; fi
      color_init
      # ensure_fresh_usage, not a bare collect_usage: --json must refresh a stale row
      # for exactly the same reason switch-auto must, and both now go through the one
      # helper. Under --no-refresh it is still cache-only, an explicit "no network"
      # outranks the implicit refresh.
      ensure_fresh_usage
      resolve_shared_identity --verify
      # the nested-config trap: silent when ~/.claude/.claude.json agrees with
      # ~/.claude.json (or does not exist), one warning when it does not
      nested_config_warning
      adopt_shared_numbers
      # v2: shared slot is credential-free, there is no live shared credential to
      # sync back into a pool dir, so the v1 self-heal call is short-circuited.
      # (sync_live_credential_back itself is kept: it no-ops without a shared file,
      # and removing it wholesale is riskier than leaving it unreferenced here.)
      compute_recommendation 0 0
      if (( as_json )); then
        [[ -n "$SHARED_WARN" ]] && printf '%s\n' "$SHARED_WARN" >&2
        [[ -n "$AUTH_WARN" ]] && printf '%s\n' "$AUTH_WARN" >&2
        [[ -n "$NESTED_WARN" ]] && printf '%s\n' "$NESTED_WARN" >&2
        # Built into a variable and validated before a byte reaches stdout, so the
        # promise "stdout is one parseable object, always" holds even if the jq
        # pipeline dies half-written: the caller then gets {"error":…} + exit 1
        # instead of a truncated object it would have to guess about.
        local json_out
        if json_out="$(json_usage)" && [[ -n "$json_out" ]] \
           && printf '%s' "$json_out" | jq -e 'type=="object"' >/dev/null 2>&1; then
          printf '%s\n' "$json_out"
        else
          die "could not build the usage object"
        fi
      else
        render_usage
      fi
      ;;
    switch-auto)
      # No-argument switch: pick the best OTHER pool-backed account by exactly the
      # rule `usage` recommends (soonest weekly reset among accounts clearing the
      # health floor), excluding whatever account the shared ~/.claude holds, then
      # run switch-all to it. --dry-run prints the pick without switching.
      #
      # SELF-EXPLAINING BY DEFAULT (2026-08-06). It used to answer with one line and
      # a pointer, "no other account clearing the health floor …, see `rota usage`"
      # which made the right call and then charged you a second command to learn
      # WHY and where the other accounts stood. The operator: "maybe it'd be good if the
      # output could also show why you made that decision and where the other
      # accounts are at, so I never have to go and check." So it now prints the SAME
      # per-account table `usage` prints (through the same renderer, see
      # render_usage_table) and the same rationale sentence (recommendation_text),
      # and THEN acts. --quiet/-q restores the old terse one-liner for scripts, and
      # keeps the pointer, since under --quiet there is no table to read instead.
      shift || true
      # Restarting idle panes is the DEFAULT (2026-08-12): a switch that only
      # affects new launches leaves every open pane billing the old account,
      # and the follow-up `--restart-idle` invocation was pure ritual.
      # --new-only opts out (only new launches adopt); --restart-idle stays
      # accepted as the EXPLICIT spelling of the default, a no-op alias for
      # scripts and muscle memory (the keeper and the dashboard both pass it),
      # and explicitness is remembered so an unreachable tmux is DIAGNOSED
      # when you asked for restarts by name, but stays silent under the
      # default (a laptop switch must not nag about a session never there).
      local dry=0 quiet=0 restart=1 restart_explicit=0
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --dry-run|-n) dry=1 ;;
          --quiet|-q)   quiet=1 ;;
          --restart-idle) restart=1; restart_explicit=1 ;;
          --new-only)   restart=0 ;;
          --verbose|-v) VERBOSE=1 ;;
          --color)      COLOR_MODE=always ;;
          --no-color)   COLOR_MODE=never ;;
          *) die "usage: rota failover switch-auto [--dry-run] [--quiet] [--new-only|--restart-idle] [--verbose] [--color|--no-color]" ;;
        esac
        shift
      done
      command -v jq >/dev/null 2>&1 || die "switch-auto needs jq"
      color_init
      # REFRESH FIRST, through the same helper the dashboard uses. The decision this
      # verb exists to make must never be made on numbers the run never tried to
      # replace (2026-08-05: every row was a cache from 2026-07-20).
      ensure_fresh_usage
      resolve_shared_identity --verify
      adopt_shared_numbers
      compute_recommendation 1 1
      # NB the cached fallback below runs BEFORE the REC_HOLD branch, which it could
      # not do when that branch returned early. It is a no-op under a hold: a hold
      # always leaves REC_SLOT at the active slot, so the (( REC_SLOT < 0 )) guard is
      # already false.
      if (( REC_SLOT < 0 )); then
        # The refresh could not land for any row, dead network, every stored token
        # stale, or the usage API 429ing the shared token that live sessions poll.
        # Retry once on the last-good CACHED numbers rather than dead-ending: the
        # dead-end is the actual harm here, because it hands the choice back to
        # the operator, which is the one thing `rota switch` with no argument exists to
        # avoid. Age-marked, said out loud on stderr, and still subject to the same
        # health floor and the same soonest-reset ranking.
        local stale_rows; stale_rows="$(usage_stale_rows)"
        compute_recommendation 1 1 1
        if (( REC_SLOT >= 0 )); then
          printf 'note: no account returned LIVE numbers this run (%s), deciding on the last-good CACHED numbers rather than making you name an account. Re-run `rota usage` once the tokens rotate to confirm.\n' \
            "${stale_rows:-reason unknown}" >&2
        fi
      fi
      # THE PICTURE, then the decision. Printed after the (possibly two-pass)
      # ranking so every row carries the reason it actually earned in the pass that
      # decided, and printed for EVERY outcome, hold, switch, or nothing to pick,
      # because "where does the pool stand" is exactly as worth answering when the
      # answer is "nowhere to go" as when it is "switch to cs".
      if (( ! quiet )); then
        # the nested-config trap rides along with the table it is rendered inside;
        # silent unless ~/.claude/.claude.json really disagrees with ~/.claude.json
        nested_config_warning
        render_usage_table
        render_recommendation
      fi
      if (( REC_HOLD )); then
        # Burn-down: the active account still has weekly headroom, so a bare
        # `rota switch` must NOT move him off it, that is the exact behaviour this
        # change exists to stop. The stay sentence is the same one the dashboard
        # prints (one source, recommendation_text); the default path has already
        # printed it above, so only --quiet still has to. Exit 0: refusing here is
        # the right answer, not an error, and `rota switch <label>` still forces it.
        (( quiet )) && recommendation_text
        (( quiet )) || render_panes_summary
        # The restart still runs here (default, or --restart-idle). It used to
        # refuse with "nothing was switched, so no pane has a new account to
        # adopt", which assumed the only way a pane can be on the wrong account
        # is a switch THIS invocation just made. False, and it cost an hour on
        # 2026-08-09: the account had already moved by another route (an
        # external /login, a Keychain shadow removed by hand, a pane pinned to
        # a pool dir whose credential was replaced), so every pane was stale
        # while the switch itself was correctly a no-op, and the one command
        # that fixes that refused to run. Restarting an idle pane is safe and
        # idempotent regardless of who moved the account: it skips mid-work
        # panes, empty titles, and the calling pane.
        if (( restart )); then restart_idle_panes "$dry" "$restart_explicit"; fi
        return 0
      fi
      if (( REC_SLOT < 0 )); then
        # Same verdict, two endings. Under --quiet the pointer is the only way to
        # see the numbers, so it stays. In the default mode the rows are already on
        # screen, so pointing at another command would be the round trip this
        # change exists to remove.
        if (( quiet )); then
          die "no other account clearing the health floor (>=$MIN_WEEKLY% weekly, >=$MIN_SESSION% 5h; current: ${SHARED_EMAIL:-unknown}), on live OR cached numbers, see \`rota usage\`"
        fi
        die "no other account clearing the health floor (>=$MIN_WEEKLY% weekly, >=$MIN_SESSION% 5h; current: ${SHARED_EMAIL:-unknown}), on live OR cached numbers, each account's numbers and the reason it was skipped are in the rows above."
      fi
      # a FRESH pick has no reset instant; printing "weekly resets " with nothing after
      # it would read as a lost timestamp rather than as an unstarted window
      local pick_when="weekly window not started yet"
      # `~` when the instant is a projection, the same mark the tables and the
      # rationale sentence use: this line is the only record of why an unattended
      # switch chose this seat, and an unmarked inference in it reads as a
      # measurement forever after.
      if [[ -n "$REC_RESET" ]]; then
        if (( REC_PROJECTED )); then pick_when="weekly resets ~$REC_RESET"
        else pick_when="weekly resets $REC_RESET"; fi
      fi
      # the cached-fallback marker is a SUFFIX, so the live-numbers line, the one
      # the operator sees every day, is byte-for-byte what it has always been
      local pick_src=""
      # A peer-sourced pick is not "cached" in the sense this line has always
      # meant (this box's own last-good numbers), so it names the box that
      # measured it instead of claiming an age from an empty local cache stamp.
      if (( REC_CACHED )); then
        if [[ "${U_STATE[$REC_SLOT]}" == "peer" ]]; then
          pick_src=" [not a live measurement: $(state_tag "$REC_SLOT")]"
        else
          pick_src=" [from CACHED numbers, ${U_TS[$REC_SLOT]:-age unknown}]"
        fi
      fi
      printf 'optimizer pick: %s (slot %s, %s; current: %s)%s\n' \
        "$REC_EMAIL" "${LABELS[$REC_SLOT]}" "$pick_when" "${SHARED_EMAIL:-unknown}" "$pick_src"
      if (( dry )); then
        echo "(dry-run, no switch performed)"
        (( quiet )) || render_panes_summary
        if (( restart )); then restart_idle_panes 1 "$restart_explicit"; fi
        return 0
      fi
      # A CALL, not the old `exec`: the panes block is the part that only makes
      # sense AFTER the swap has landed, so this frame has to survive it. The
      # exit code is passed straight through, so nothing that scripts this verb
      # can tell the difference. The restart decision is HANDED to switch-all
      # (bare = its default restart, --restart-idle = the explicit spelling,
      # --new-only = skip), never done here as well, two restarts of the same
      # panes back to back was the one way the handoff could go wrong.
      local sw_rc=0 swa_args=("${LABELS[$REC_SLOT]}")
      if (( restart )); then
        (( restart_explicit )) && swa_args+=(--restart-idle)
      else
        swa_args+=(--new-only)
      fi
      "$0" switch-all "${swa_args[@]}" || sw_rc=$?
      (( quiet )) || render_panes_summary
      return "$sw_rc"
      ;;
    switch-all)
      # ── POINTER SWITCH (pool v2, 2026-08-11) ─────────────────────────────
      # HISTORY, kept because every rule below was paid for: v1 switch-all
      # COPIED the target's credential into the shared ~/.claude (stashing the
      # outgoing one under creds/<email>.json), then fought the consequences,
      # Keychain shadowing (2026-08-09), husk-over-stash clobbers (2026-08-07),
      # pinned sessions rewriting the file mid-swap (2026-07-19, 2026-07-27).
      # With the shim installed NOTHING reads the shared copy, every session
      # lives in its own pool dir, so the copy was pure risk with zero
      # function, and single-use refresh tokens made every copy a time bomb.
      # v2: credentials never move. Switching is rewriting the ~/.claude.json
      # claim (what every new shim launch resolves) and deleting any stray
      # shared credential/Keychain item so nothing can bill through it.
      shift || true
      # Restarting idle panes after the pointer moves is the DEFAULT
      # (2026-08-12): --new-only opts out, --restart-idle stays accepted as the
      # explicit no-op spelling of the default (keeper + the dashboard pass it),
      # and only the explicit form diagnoses an unreachable tmux out loud.
      local want="" restart_idle_after=1 restart_explicit=0 swa
      for swa in "$@"; do
        case "$swa" in
          --restart-idle) restart_idle_after=1; restart_explicit=1 ;;
          --new-only) restart_idle_after=0 ;;
          -*) die "usage: rota failover switch-all <label-substring> [--new-only|--restart-idle]" ;;
          *)  [[ -z "$want" ]] && want="$swa" || die "switch-all: one target at a time (got '$want' and '$swa')" ;;
        esac
      done
      [[ -n "$want" ]] || die "usage: rota failover switch-all <label-substring> [--new-only|--restart-idle]"
      local shared="$HOME/.claude" cred="$HOME/.claude/.credentials.json"
      # resolve target account by label substring OR pool-dir basename (an alias
      # like "work" need not appear in the email at all; ~/.claude-pool/work still
      # makes it a natural name)
      local ti=-1 i
      for i in "${!LABELS[@]}"; do
        [[ "${LABELS[$i]}" == *"$want"* || "$(basename "${DIRS[$i]}")" == "$want" ]] && { ti="$i"; break; }
      done
      (( ti >= 0 )) || die "no account label matches '$want' (labels: ${LABELS[*]}; dir aliases: $(for d in "${DIRS[@]}"; do basename "$d"; done | tr '\n' ' '))"
      local tlabel="${LABELS[$ti]}" tdir="${DIRS[$ti]}"
      if [[ "$tdir" -ef "$shared" ]] 2>/dev/null; then
        die "$tlabel's mapped dir IS the shared ~/.claude, the v2 pointer switch needs a pool dir (the shared slot is credential-free). Give it one: mkdir ~/.claude-pool/<alias>, CLAUDE_CONFIG_DIR=~/.claude-pool/<alias> claude → /login, then fix the accounts file (rota reconcile)."
      fi
      # 1. RESOLVE BY IDENTITY, never by position (the same rule the shim
      #    applies at launch). The map said personal; the dir held work; every
      #    "personal" launch billed the work seat for weeks, so the dir's own .claude.json
      #    outranks the accounts file here too.
      local tid; tid="$(config_email "$tdir")"
      if [[ -n "$tid" && "$tid" != "$tlabel" ]]; then
        local nmatch=0 match=-1 j jid
        for j in "${!DIRS[@]}"; do
          [[ "${DIRS[$j]}" -ef "$shared" ]] 2>/dev/null && continue
          jid="$(config_email "${DIRS[$j]}")"
          [[ "$jid" == "$tlabel" ]] && { nmatch=$((nmatch + 1)); match=$j; }
        done
        if (( nmatch == 1 )); then
          # shellcheck disable=SC2016  # literal backticks around the command to run
          printf 'note: the accounts file maps %s to %s, but that dir holds %s, switching to %s, the dir that actually holds it. Run `rota reconcile` to fix the map.\n' \
            "$tlabel" "$(tilde "$tdir")" "$tid" "$(tilde "${DIRS[$match]}")" >&2
          mkdir -p "$CFG_DIR" 2>/dev/null || true
          touch "$CFG_DIR/needs-reconcile" 2>/dev/null || true
          tdir="${DIRS[$match]}"
        else
          die "identity mismatch: the accounts file maps $tlabel to $(tilde "$tdir"), but that dir holds ${tid:-no identity} and $nmatch dirs hold $tlabel, run \`rota reconcile\` (and, if two dirs claim one account, re-login one of them) before switching."
        fi
      fi
      # 2. REFUSE A HUSK. A pointer aimed at a dir whose credential cannot
      #    answer is a login prompt wearing a switch's clothes, name the one
      #    browser login that fixes it instead.
      local tcred="$tdir/.credentials.json"
      if ! cred_is_complete "$tcred"; then
        die "refusing to switch to $tlabel: its stored credential at $(tilde "$tcred") is missing or a husk (no usable refresh token/expiry). It needs one browser login: CLAUDE_CONFIG_DIR=$(tilde "$tdir") claude → /login, then re-run."
      fi
      # 3. MOVE THE POINTER, the whole oauthAccount object, so the displayed
      #    identity stays internally consistent (same helper as v1).
      move_oauth_account "$tdir" "$tlabel"
      # 4. THE SHARED SLOT IS CREDENTIAL-FREE, idempotent hygiene, not a swap.
      #    Any credential still sitting in ~/.claude predates v2 (or leaked in
      #    via an unpinned /login) and can only ever husk someone's chain.
      if [[ -e "$cred" || -L "$cred" ]]; then
        rm -f "$cred" 2>/dev/null \
          && printf 'removed the shared ~/.claude credential (v2: the shared slot holds no credential, sessions bill through their pool dirs)\n' >&2 \
          || printf 'WARNING: could not remove %s, delete it by hand; a shared credential can husk a pool chain\n' "$(tilde "$cred")" >&2
      fi
      local kc_state
      kc_state="$(purge_shared_keychain)"
      case "$kc_state" in
        removed) echo "removed stale shared Keychain item(s) (both service-name shapes probed)" >&2 ;;
        stuck)   echo "WARNING: a shared Keychain item could not be deleted, inspect with: security dump-keychain | grep Claude" >&2 ;;
      esac
      # 5. VERIFY: the claim re-read (retried, running sessions rewrite
      #    ~/.claude.json and the write can lose that race) + the target dir's
      #    identity. Nothing else: no byte comparison (there are no shared
      #    bytes to compare), no usage-API round trip, no `claude` subprocess.
      local tries="${CLAUDE_FAILOVER_VERIFY_TRIES:-5}"
      local nap="${CLAUDE_FAILOVER_VERIFY_SLEEP:-1}"
      local new_email='' attempt=1
      while (( attempt <= tries )); do
        new_email="$(json_email "$HOME/.claude.json")"
        [[ "$new_email" == "$tlabel" ]] && break
        if (( attempt < tries )); then sleep "$nap"; fi
        attempt=$((attempt + 1))
      done
      local dir_id_now; dir_id_now="$(config_email "$tdir")"
      if [[ "$new_email" == "$tlabel" && "$dir_id_now" == "$tlabel" ]]; then
        printf 'active account is now %s (pointer switch, no credential moved; %s keeps its own chain).\n' "$tlabel" "$(tilde "$tdir")"
        # shellcheck disable=SC2016  # literal backticks around commands to run
        if (( restart_idle_after )); then
          printf 'New `claude` launches pin to %s via the shim immediately; idle panes (if any) are restarted onto it below (default; --new-only to skip). Mid-work panes keep their pinned account until the keeper'"'"'s pane-converge restarts them once idle.\n' \
            "$(tilde "$tdir")"
        else
          printf 'New `claude` launches pin to %s via the shim immediately. --new-only: no panes restarted, already-running sessions keep their own pinned account until restarted (re-run `rota switch %s` without --new-only, or restart panes by hand).\n' \
            "$(tilde "$tdir")" "$(basename "$tdir")"
        fi
      elif [[ "$new_email" != "$tlabel" ]]; then
        printf 'WARNING: wrote oauthAccount=%s but ~/.claude.json reads %s after %d tries, a running session is rewriting the claim over ours. Quit or /login that session, then re-run switch-all.\n' \
          "$tlabel" "${new_email:-unknown}" "$tries" >&2
        return 1
      else
        # shellcheck disable=SC2016  # literal backticks around the command to run
        printf 'WARNING: the claim moved to %s but %s now reports identity %s, the dir changed identity mid-switch (a /login race?). Run `rota reconcile` and re-run switch-all.\n' \
          "$tlabel" "$(tilde "$tdir")" "${dir_id_now:-none}" >&2
        return 1
      fi
      if (( restart_idle_after )); then restart_idle_panes 0 "$restart_explicit"; fi
      ;;
    pane-converge)
      # restart idle panes whose pinned pool account differs from the claim;
      # busy panes are reported and picked up on a later run (keeper step 4b).
      shift || true
      cmd_pane_converge "$@"
      ;;
    reconcile)
      # pool v2: rewrite the accounts-file mapping from dir identities.
      shift || true
      cmd_reconcile "$@"
      ;;
    normalize)
      # pool v2: un-swap two dirs holding each other's accounts (process-free only).
      shift || true
      cmd_normalize "$@"
      ;;
    adopt-shared)
      # pool v2 bootstrap: MOVE the shared ~/.claude login into its pool dir.
      shift || true
      cmd_adopt_shared "$@"
      ;;
    status)
      # loggedIn used to come from `claude auth status` per dir, which on this box
      # reported the LIVE account as not-logged-in (its pool copy is stale by design
      # running sessions burn its single-use refresh tokens), so the dashboard greyed
      # out the one account actually in use. It is now: has a usable stored
      # credential, OR is the account governing the shared ~/.claude. No network and
      # no auth status, the dashboard polls this.
      local cur; cur="$(current_index)"
      resolve_shared_identity --fast
      printf 'accounts (%d), current = %d:\n' "${#DIRS[@]}" "$((cur+1))"
      local i
      for i in "${!DIRS[@]}"; do
        local mark=' '; [[ "$i" == "$cur" ]] && mark='*'
        # slot_logged_in is the same predicate `usage --json`'s loggedIn publishes,
        # one rule, so the roster the phone parses out of THIS output can never
        # disagree with the boolean the JSON hands it
        local logged=false
        slot_logged_in "$i" && logged=true
        printf ' %s [%d] %-40s loggedIn=%s  %s\n' "$mark" "$((i+1))" "${LABELS[$i]}" "$logged" "${DIRS[$i]}"
      done
      ;;
    *)
      # No subcommand → launch the current account, passing all args through.
      launch "$(current_index)" "$@" ;;
  esac
}

main "$@"
