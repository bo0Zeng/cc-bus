# cc-bus

**English** | [中文](README.zh-CN.md)

A message bus for multiple independent **Claude Code** instances running in tmux — let separate
sessions send / relay / broadcast messages to each other, and spawn directory-rooted collaborator
sessions, with smart routing and an optional broker daemon.

Claude Code has no native way to message an *already-running* instance. cc-bus adds one: messages are
delivered by `tmux send-keys` (a "knock"), persisted to a per-instance inbox file (the single source
of truth), and routed through a pipeline (ACL / rate-limit / dedup / loop-cut / knock-debounce). A
`Stop` hook drains the inbox even when a session is busy, so nothing is lost if the peer isn't idle.

## Two language editions — pick one

This repo ships the **same plugin in two languages**, as two self-contained copies:

| Directory | Edition | Docs, comments, and user-facing strings |
|-----------|---------|------------------------------------------|
| [`en/`](en/) | English | English |
| [`zh/`](zh/) | 中文    | Chinese |

Both are byte-for-byte identical in behavior — only the natural-language text differs. Install
whichever you prefer; you don't need both.

## What you get

- **Send / relay / broadcast** between running sessions (`cc-send`, `cc-broadcast`).
- **Passive receive** — a `SessionStart` hook auto-registers the session; a `Stop` hook delivers
  queued messages before the turn ends (works even while the peer is mid-task).
- **Automatic identity** from tmux (session name; override via the `@cc_id` pane option or
  `$CC_BUS_ID`). No manually-assigned IDs.
- **Smart routing**, all **off by default** (behaves like a plain bus): per-pair & global rate
  limits, ACL / star topology, dedup, loop-cut, knock-debounce.
- **Optional broker daemon** `cc-busd` for centralized async delivery; without it, `cc-send` runs the
  *same* routing pipeline inline, so messages are never dropped.
- **Spawn collaborators** — `cc-spawn <dir> [task]` opens an independent Claude Code session rooted in
  a directory (isolated history, native file access), auto-joined to the bus. `cc-kill` / `cc-agents`
  manage their lifecycle. Distinct from a subagent: a real, long-lived, separate-context process.

## Requirements

- **Linux** (uses `flock`, `pgrep`, `/proc`), **bash 4+**, **tmux**.
- **`jq`** (envelope build/parse) and **`flock`** from util-linux (concurrency safety) — both required.
- **Claude Code** with plugin support (or install manually, see below).

## Install

Everything below uses the English edition (`en/`); for Chinese, replace `en/` with `zh/`.

### As a Claude Code plugin

```bash
/plugin install cc-bus      # from a marketplace, or add this repo (the en/ or zh/ subdir) as a plugin source
```

Installing the plugin auto-activates the **hooks** and the **skill**. But Claude Code's plugin system
does **not** put the `cc-*` scripts on your shell `PATH` — passive receive works immediately, while
**active send / broadcast / spawn need the commands on `PATH`**, so run the installer once:

```bash
bash en/install.sh   # symlinks 11 cc-* commands → ~/.local/bin, creates ~/.cc-bus/
```

Make sure `~/.local/bin` is on your `PATH` (most distributions add it by default). The installer never
overwrites an existing same-named command — it skips and warns instead.

### Manual (without the plugin system)

```bash
git clone https://github.com/bo0Zeng/cc-bus && cd cc-bus
bash en/install.sh
```

Then add the two hooks to `~/.claude/settings.json` (see [`en/hooks/hooks.json`](en/hooks/hooks.json)
for the shape) pointing at the installed `cc-register` / `cc-bus-stop-hook`. The installer prints the
exact activation steps.

## How it works

**Deliver by knock, arrive by hook, dedup by offset, route by pipeline, carry by broker + fallback,
shape by policy.**

- **Single source of truth:** `~/.cc-bus/inbox/<id>.jsonl` — each message is one appended envelope,
  consumed by byte offset (so redelivery and dedup are exact).
- **Envelope (v2):** `{id, from, to, ts, text, class, in_reply_to, trace, hops, prio}`.
- **Pipeline** (one implementation in `scripts/cc-bus-lib.sh`, shared by the daemon and the inline
  fallback): ACL → rate/breaker → loop-cut → dedup → write inbox → knock-debounce.

All runtime data lives under `~/.cc-bus/` (per-user, single host): `inbox/*.jsonl`, `state/*`
(offsets / causal cursors / debounce), `agents.tsv` (roster), `queue/`, `log/`, `config`, `policy.tsv`.
**None of it is in this repo** — the repo holds only code.

## Usage

cc-bus is driven by an **agent-facing skill** (`skills/cc-bus/SKILL.md` in each edition) — the running
Claude Code instance reads it and calls the `cc-*` commands itself when you ask it, in natural
language, to contact / notify / broadcast to another session, or to spawn one in a directory. You don't
run the commands by hand.

The skill also carries a **communication discipline** (verify before answering; quote-and-attribute
when relaying; resist sycophantic rubber-stamping; label confidence and intent) so information doesn't
get distorted as it passes between agents.

## Routing (optional)

Everything is off by default. Configure in `~/.cc-bus/config` (sourceable `KEY=VAL`) plus
`~/.cc-bus/policy.tsv` (ACL); see each edition's `examples/`. Changes take effect immediately (hot
reload). Common knobs: `CCBUS_RATE_PAIR` / `CCBUS_RATE_GLOBAL` (anti-storm), `CCBUS_POLICY_MODE=on` +
`policy.tsv` (star topology), `CCBUS_DEDUP_WINDOW`, `CCBUS_TTL`.

## Broker daemon (optional)

```bash
cc-busd start | stop | status
```

Or install it as a `systemd --user` service — see each edition's `examples/cc-busd.service`. Without
the daemon, `cc-send` falls back to the same pipeline inline (note: a pure-fallback deployment has no
crash-recovery reaper — run `cc-busd` if you need that).

## Uninstall

Remove the hooks from `settings.json` (or uninstall the plugin), run `cc-busd stop`, and delete the
`cc-*` symlinks in `~/.local/bin`. Runtime data remains under `~/.cc-bus/` until you delete it.

## Development

The two editions carry identical behavior — only the natural-language text (comments, docs, and
user-facing strings) differs. When you change code, apply the same change to **both** `en/` and `zh/`;
when you change docs/comments/strings, keep the two editions in sync. The `en/` edition is a
translation of the `zh/` edition.

## License

[MIT](LICENSE).
