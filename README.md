# rota

**rota** manages several Claude Max subscriptions that you own and pay for, on your own machines, so that no week of allowance you have bought goes unused. Each subscription is a *seat*. Every seat has its own weekly window and its own five-hour window, both use-it-or-lose-it, and if you run more than one seat the question every morning is the same: which one should today's work bill to, and are any of them about to hit a wall? rota answers that, keeps the answer fresh, and pins every `claude` you start to the seat it picked.

It is not a proxy, it does not share one login between people, and it does not route around a plan's limits. It reads the same usage numbers the Claude Code status line shows and chooses between accounts that are all yours.

## The problem

You have two (or five) Claude Max seats. Claude Code keeps exactly one login in `~/.claude`, so switching means logging out and in, and every session on the box changes account under you when you do. Worse, Claude Code's OAuth refresh tokens are single-use: if a credential ever exists in two places and both refresh, one of them dies, and you are typing `/login` again a week later without knowing why.

Meanwhile the seat you are not using is quietly wasting its week.

## The mental model

Four ideas, and everything else follows from them.

1. **One seat, one directory, one refresh chain.** Every seat lives in `~/.claude-pool/<seat>/` as its own `CLAUDE_CONFIG_DIR`. A credential is written there once by `/login` and is never copied, moved, or stashed anywhere else. Settings, skills and transcripts are shared back into `~/.claude` by symlink, so switching seats does not lose your history.
2. **"Active seat" is a pointer, not a credential location.** Switching rewrites which seat *new* launches use. A running session keeps the seat it was born with until it restarts.
3. **A shim pins every launch.** `rota` installs a tiny wrapper as `~/.local/bin/claude`. A bare `claude` reads the pointer, exports that seat's `CLAUDE_CONFIG_DIR`, and execs the real binary. An explicit `CLAUDE_CONFIG_DIR` in your environment always wins over the shim.
4. **A daemon does the thinking.** Every ten minutes the keeper reads live usage for every seat, and when the active seat crosses 90% of either window it switches the pointer to the seat whose weekly window resets *soonest* and still has room. Soonest-first, because a window that resets tomorrow is the one whose remaining allowance is about to evaporate.

## Install

Requirements: macOS (launchd is used for the daemon; the CLI itself also runs on Linux), `bash`, `jq`, `python3`, `curl`, and Claude Code installed (Homebrew or the native installer).

```sh
git clone https://github.com/tomburgerch/rota ~/.local/share/rota && ~/.local/share/rota/install.sh
```

The installer symlinks `rota` and the `claude` shim into `~/.local/bin`, creates `~/.config/claude-failover/`, and installs two launchd agents (the keeper, every 10 min, and a credential watchdog, every 5 min). It tells you if `~/.local/bin` is not ahead of the real `claude` on your `PATH`; that ordering is the whole trick, so fix it before going on. `install.sh --uninstall` reverses everything and leaves your logins alone.

Then describe your seats, one per line, as `<label>|<directory>`:

```sh
cp ~/.local/share/rota/config/accounts.example ~/.config/claude-failover/accounts
$EDITOR ~/.config/claude-failover/accounts      # e.g.  work@example.com|~/.claude-pool/work
rota pool-init                                  # creates the directories and symlinks
```

Log into each seat once. This is the only manual step there will ever be:

```sh
rota login work        # opens claude pinned to that seat; type /login, finish in the browser, exit
rota login personal
```

## The commands you actually type

| Command | What it does |
|---|---|
| `rota usage` | One row per seat: weekly and five-hour windows, when each resets, how fresh the number is, and which seat live sessions are billing to right now. |
| `rota switch` | Pick the best seat (soonest weekly reset with room left) and make it active. `rota switch <seat>` names one. Idle sessions restart onto it; sessions mid-work are left alone and converge later. |
| `rota login <seat>` | Open Claude pinned to one seat so `/login` lands in the right directory. |
| `rota status` | The pointer and every seat's credential health. `rota keeper-status` shows what the daemon did on its last tick, and its log. |
| `rota billing` | The usage table plus what each seat costs and when it renews, from `~/.config/claude-failover/billing.json` (no API exposes this, so you maintain it; start from `config/billing.example.json`). |

Everything else (`reconcile`, `normalize`, `cred-guard`, `cred-restore`, `adopt-shared`, `repair-nested`) exists for the failure modes below and is listed by `rota help`.

## What it does not do

- It does not share a seat between people or machines. One login per seat per machine, every time.
- It does not copy credentials. Ever. If you find yourself scp'ing a `.credentials.json`, you are about to create the twin-chain problem it exists to prevent.
- It does not change the account of a session that is already running.
- It does not touch headless containers or CI runners (a per-container `CLAUDE_CONFIG_DIR` already solves that with one line of config).
- It does not know what anything costs; `billing.json` is yours to keep.

## Failure modes it handles (and why you want somebody else's tool)

Every one of these cost real hours before it was understood.

**A seat that has not been used since its weekly window rolled over cannot be measured.** The usage API reports the *old* window, so the seat reads as expired or walled when it is in fact untouched. There is no number to read until one request opens a new window. rota shows such a row as `no active window yet (starts on first use)` rather than a stale percentage, and the keeper opens a window with one minimal call at `WARM_AT` (03:00 by default) so the morning starts against a measurable seat. Two seats sat invisible for days before this was understood.

**The usage probe returns 429 when many sessions share a token.** Fifteen panes on one seat and the usage endpoint starts refusing. rota never presents a 429 as a number: the row falls back to the last good cached read, marked with its age, and stays marked stale until a live read succeeds. Nothing switches on a stale row.

**A credential slot can be raced by an unpinned session.** If any session on the box was started without the shim (a copy of `claude` earlier on `PATH`, an IDE plugin, an old alias) it writes into the shared `~/.claude`, and the next switch would move a live chain. The watchdog (`rota cred-guard`, every five minutes) detects a shared credential that belongs to a pooled seat, snapshots both copies, and writes a report naming the seat, both directories and the one command that ends the race. It moves nothing itself, and the engine's `adopt-shared` refuses to run while the race is live rather than papering over it. A `/login` typed into a pane that was pinned to the wrong seat is detected by the keeper and homed into the right directory on the first tick after that pane exits (the keeper never moves a credential a live process holds); do not log in a second time, every extra login mints another chain.

**A seat can be walled at the per-model cap while its headline weekly number looks healthy.** The weekly window has sub-buckets (Opus, Sonnet) with their own caps. rota reads the per-model rows and uses the binding one as the seat's weekly figure, so a seat whose Opus bucket is exhausted is treated as walled for switching purposes even though the headline says 40% left. `rota usage` shows which bucket is binding. It reports the measured bucket only, never a guess, because a warning that cries wolf is one you learn to ignore.

Two more the README owes you: on macOS, Claude Code stores a directory's credential in the file *and* in a per-directory Keychain item depending on how the process was launched (GUI versus SSH/tmux), and the two are twin chains inside one directory; the keeper unifies them every tick, keeping whichever is newer. And `~/.claude/.claude.json` nested inside the config dir is a trap that makes probes report a frozen account; `rota repair-nested` replaces it with a symlink.

## Layout

```
bin/rota                the command
lib/rota-engine.sh      seats, usage, switching, convergence
lib/rota-keeper.sh      the daemon (launchd, every 10 min)
lib/rota-cred-guard.sh  the watchdog (launchd, every 5 min)
lib/rota-shim.sh        installed as ~/.local/bin/claude
lib/rota-billing.sh     the cost table
config/*.example        accounts, keeper.conf, billing.json
skills/rota/SKILL.md    the rules an agent must follow around the pool
tests/run.sh            hermetic test suites (fake HOME, stubbed claude)
```

State lives in `~/.config/claude-failover/` (the accounts map, `usage-cache.json`, `keeper.log`, `keeper-status`) and the seats in `~/.claude-pool/`. Knobs are in `~/.config/claude-failover/keeper.conf`; every one is listed with its default in `config/keeper.conf.example`.

## For Claude Code agents

If you run Claude Code sessions that themselves run `claude` (subagents, automation, tmux fleets), point them at `skills/rota/SKILL.md`. The short form: identity comes from the directory, never from a name; never set `CLAUDE_CONFIG_DIR=$HOME/.claude`; never move a credential; read quota through `rota usage --json`, not your own probe.

## Tests

```sh
tests/run.sh
```

Every suite runs against a throwaway `HOME` with a stubbed `claude`, `security`, `curl` and `tmux`, so it never touches a real login.

## Licence

MIT.
