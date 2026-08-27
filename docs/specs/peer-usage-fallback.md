# Peer usage fallback: `rota accounts` shows every seat's quota on every box

## The situation

`cdt accounts` (→ `rota accounts`) is the one table Cédric reads to answer "how much
have I got left, on which seat, and what is it costing me". On **ballito** it answers
that completely. On **durban**, the laptop he actually works on, four of the five rows
are blank:

```
  SEAT                                  WEEKLY LEFT    5H   GONE IN  QUOTA RESETS      NOTES
  cedric.waldburger@codeandstate.com              -     -         -  -                 [quota none]
  tartare@codeandstate.com                        -     -         -  -                 CANCELLED  [quota none]
  thea.hawk@tomahawk.vc                           -     -         -  -                 CANCELLED  [quota none]
  cedric.waldburger@gmail.com <    ████░░░░░    39%   97%    2d 03h  Sat 29 Aug 16:00   RESERVED → airmond-runner
  tommy.hawk@tomahawk.vc                          -     -         -  -                 RESERVED → joe  [quota none]
```

He has asked for the full table repeatedly and kept getting this one, so the columns
and the CANCELLED / RESERVED annotations are **not** the gap: those already work. The
gap is the numbers.

### Root cause (established, not guessed)

The quota columns are blank because **durban has no credential for those four seats.**

- `~/.claude-pool/{thea,cs,tartare,tommy}/.credentials.json` — all four **absent** on
  durban; only `gmail` has one.
- The per-config-dir Keychain items (`Claude Code-credentials-<sha256(dir)[0:8]>`) are
  **absent** for all five; `security dump-keychain | grep -c Claude` → `0`.
- `$CFG_DIR/usage-cache.json` on durban holds **exactly one key**,
  `cedric.waldburger@gmail.com`.

So in `collect_usage`, those four slots get no token → no live fetch → `cache_get`
returns nothing → `U_STATE[i]="none"` → every quota cell renders `-` and the row is
annotated `[quota none]`. The code is behaving correctly on the input it has.

Meanwhile **ballito holds all five credentials**, and the keeper's step 3 (USAGE) does
one `/api/oauth/usage` fetch per account per tick, so ballito's `usage-cache.json` has
all five accounts and stays warm. `ssh ballito 'rota accounts --json'` already returns
a complete, well-shaped object with every field this table needs.

### The fix, and the one option that is explicitly rejected

**Rejected: copy the credentials to durban.** `$CFG_DIR/cred-guard-report.txt` on this
very box is currently warning about exactly this for gmail: the OAuth refresh token is
**single-use**, so two boxes holding one account's credential means whichever rotates
first invalidates the other, the loser 401s, and the CLI hollows its file into a husk.
That is the documented 2026-08-07 incident. Do not introduce a second copy of any
credential to fix a *display* problem.

**Chosen: read the numbers from the box that legitimately holds the credential.** No
credential ever moves. `rota accounts --json` over ssh is read-only and already exists.

## Requirements

### R1 — Peer configuration

- New optional config file `$CFG_DIR/peers`: one host per line, `#` comments and blank
  lines ignored. A host is an ssh destination (`ballito`), so the existing
  LAN→Tailscale→Cloudflare ssh fallback for that name is inherited for free.
- Also honour `ROTA_PEERS` (space/comma separated) as an override, for tests.
- **Default when neither is set:** no peers (behaviour is exactly as today). Do NOT
  hardcode `ballito` into the engine — it goes in the config file, which
  `install.sh` / `pool-init` may seed.
- Never treat the local host as a peer: skip any entry equal to `hostname -s`,
  `scutil --get LocalHostName`, or `$HOSTNAME`.

### R2 — When a peer is consulted

Only when **all** of these hold:
- at least one peer is configured, AND
- `NET=1` (so `--no-refresh` / `-n` still does zero network), AND
- after the normal local pass, at least one slot is `U_STATE[i]="none"` **or**
  `"cached"`. (A box where every row is live never pays the ssh cost.)

One ssh per peer, in configured order, stopping at the first that answers usefully.

### R3 — Latency and failure are non-negotiable

- The whole peer step is bounded. `ssh -o BatchMode=yes -o ConnectTimeout=4
  -o StrictHostKeyChecking=accept-new` wrapped so the total cannot exceed ~10s.
- **Any** failure (host down, ssh refused, no `rota` on the peer, non-zero exit,
  unparseable JSON, jq missing) degrades **silently** to today's exact output. A peer
  problem must never produce an error the operator has to read, never a stack trace,
  and never a hang. At `--verbose` it may print one explanatory line.
- Result is cached at `$CFG_DIR/peer-usage-cache.json` with a **90s TTL**, so a
  human running `cdt accounts` twice in a row pays the round trip once. The TTL is
  overridable via `ROTA_PEER_TTL` for tests. A cache write must be atomic
  (`tmp.$$` + `mv`), matching `cache_put`.

### R4 — Precedence (which number wins)

Per slot, in order:
1. **Local live** — always wins. A live local fetch is the freshest possible truth.
2. Otherwise, between **local cache** and **peer**, take the one with the newer
   measurement timestamp (peer freshness = the peer payload's `generated_at`).
3. Nothing available → today's `-` / `[quota none]`.

A peer row is only usable for a slot when the peer's `account` **email matches the
slot's email exactly**. Never match on alias — aliases are per-box directory names and
can legitimately differ.

### R5 — Provenance must be visible

A number Cédric did not measure on this box must say so. Introduce state `peer`:

- NOTES gains `[via <host>]`, or `[via <host>, 4m old]` when the peer payload is older
  than 120s. It composes with the existing CANCELLED / RESERVED annotations rather
  than replacing them.
- The footer legend, currently `quota is measured live; billing comes from
  billing.json; …`, gains a clause naming the peer when any row used one.
- `--json`: such a row gets `"quota_data": "peer"` and a new
  `"quota_source": "<host>"`. Rows measured locally keep their current
  `quota_data` and get `"quota_source": null`. Add `"generated_at"` passthrough
  for the peer payload under a top-level `"peer": {"host":…, "generated_at":…}`
  when a peer was used, else `"peer": null`.

### R6 — Ranking safety

`USE NEXT` / `NOT OFFERED` decide where to send real work. A peer-sourced row is
**real data about a real seat** and should participate in the ranking exactly as a
`cached` row does today — check how `usage_row_stale` and the switch-auto path treat
`cached` and make `peer` behave identically. **Do not** let a peer row silently become
eligible for anything `cached` is excluded from. If `switch-auto` currently demands
live rows, `peer` must be excluded there too.

## Out of scope

- Moving, copying or refreshing any credential.
- Re-enabling the keeper's KEEPALIVE nudge (disabled 2026-08-17, cdt #544 — it husked
  credentials and rotated nothing).
- Changing the columns, the billing half, or the reservation mechanics.

## Verification (all of it, evidence pasted into the PR)

1. `tests/run.sh` — full suite green. Report the pass count.
2. New hermetic cases in `tests/engine.test.sh` (stub the peer call via
   `ROTA_PEERS` + a fake ssh on PATH, the suite already stubs `security`/`curl`
   this way):
   - peer fills a `none` slot, and NOTES shows `[via <host>]`
   - local live beats a peer row for the same slot
   - fresher local cache beats an older peer row, and vice versa
   - peer unreachable → byte-identical output to no-peer
   - `--no-refresh` performs no peer call at all
   - alias collision does not cross-match (match is on email)
   - `--json` carries `quota_data:"peer"` + `quota_source`
3. **Live proof on durban** (this is the acceptance test):
   `printf 'ballito\n' > ~/.config/claude-failover/peers && cdt accounts`
   → all five rows show WEEKLY LEFT, 5H, GONE IN and QUOTA RESETS; the four
   peer-sourced rows say `[via ballito]`; CANCELLED and RESERVED → joe still show.
   Paste the real output.
4. `time cdt accounts` twice in a row — second run must be visibly faster (TTL cache).
5. `cdt accounts` on **ballito** unchanged (it has no peers configured, and every row
   is local). Paste it.

---

## Amendments (measured on durban → ballito, 2026-08-27, after the spec was written)

### A1 — the peer call is `--no-refresh` (R2)

Measured round trips from durban:

| call | time |
|---|---|
| `ssh ballito 'echo ok'` | 2.16s |
| `ssh ballito 'rota accounts --json'` | 4.12s |
| `ssh ballito 'rota accounts --json --no-refresh'` | 2.46s |

The ssh handshake dominates (ballito's name resolves through a LAN → Tailscale →
Cloudflare fallback chain). Ballito runs `com.rota.keeper` on a **600s** StartInterval
and keeper step 3 already fetches usage per account per tick, so its cache *is* the
freshest thing on offer: forcing a refresh costs ~1.7s and buys nothing.

**The peer command is `rota accounts --json --no-refresh`.** The ~10s hard bound from
R3 stays, because the Cloudflare leg can be slow.

### A2 — age is shown on every non-live row, not only peer rows (R5)

Ballito's own cache, checked against `date -u`:

```
cedric.waldburger@codeandstate.com  fetched=2026-08-27T10:20:25Z   24s old
cedric.waldburger@gmail.com         fetched=2026-08-27T10:20:25Z   24s old
thea.hawk@tomahawk.vc               fetched=2026-08-27T10:20:25Z   24s old
tartare@codeandstate.com            fetched=2026-08-26T17:23:46Z   ~17 HOURS old
tommy.hawk@tomahawk.vc              fetched=2026-08-24T22:59:20Z   ~2.5 DAYS old
```

The two stale rows are exactly the two whose stored `expiresAt` is already in the past
(tartare ~-17h, tommy ~-59h). Their access tokens are dead and the keeper cannot rotate
them either, because no session ever runs on those seats. **This staleness is
structural and will persist**, so the table has to be honest about it rather than treat
it as a transient.

Today tommy renders as a confident `27%` weekly behind a bare `[quota cached]` with no
age. That is the exact failure this feature exists to prevent: a number of unknown
vintage shown like a live one is worse than a blank, because a blank sends Cédric to
look while a stale number quietly misinforms him.

So provenance **and age** apply to any row not measured live on this box:

- local cached → `[cached, 2d old]`
- peer, fresh → `[via ballito]`
- peer, stale → `[via ballito, 2d old]`

Reuse the existing `cache_age` / `U_TS` / `U_AGE` machinery rather than adding a second
age formatter. Keep the form coarse and glanceable (`4m`, `3h`, `2d`), never a
timestamp. Show the age once it exceeds ~120s; below that the bare source marker is
enough.

`--json` additionally carries `"quota_measured_at"` (ISO 8601, the real measurement
time of whatever number that row holds), alongside `quota_data` / `quota_source`.

This widens the change slightly beyond peer rows, into how *cached* rows render. That
is deliberate and in scope: it is one defect (an unlabelled number of unknown vintage),
and fixing half of it would leave the two seats Cédric most needs to distrust looking
the most trustworthy. Add a hermetic case for a stale **local** cached row showing its
age with **no peer configured at all**.
