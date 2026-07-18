#!/usr/bin/env bash
# cc-bus install script — symlinks the scripts into PATH, creates the runtime directories, and drops in example configs.
# [Only performs a reversible local install]: does not touch the global settings.json, does not run systemctl. Prints the activation steps you need to do by hand at the end.
# Overridable via environment variables (for testing): CCBUS_BINDIR (default ~/.local/bin), CC_BUS_HOME (default ~/.cc-bus).
set -euo pipefail
SRC=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)     # canonical source directory of the script
BINDIR="${CCBUS_BINDIR:-$HOME/.local/bin}"
BUSHOME="${CC_BUS_HOME:-$HOME/.cc-bus}"
SKILLDIR=$(dirname "$SRC")                                # skills/cc-bus

mkdir -p "$BINDIR" "$BUSHOME"/{inbox,state,log,queue}

# Symlink the executable scripts (cc-bus-lib.sh is not symlinked: each script uses readlink -f to locate its real directory and sources it from there)
# Do not silently overwrite a user's pre-existing command of the same name: only refresh old symlinks that already point into this repo's scripts/, skip everything else with a warning.
skipped=""
for s in cc-whoami cc-register cc-send cc-recv cc-list cc-broadcast cc-bus-stop-hook cc-busd cc-spawn cc-kill cc-agents; do
  chmod +x "$SRC/$s"
  dst="$BINDIR/$s"
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    cur=$(readlink -f "$dst" 2>/dev/null || true)
    case "$cur" in
      */scripts/"$s") ;;                    # old symlink from this repo (live checkout or a distributed copy) → refresh
      *) skipped="$skipped $s"; continue;;  # an unrelated command with the same name → do not overwrite
    esac
  fi
  ln -sf "$SRC/$s" "$dst"
done
chmod +x "$SRC/cc-bus-lib.sh"
[ -n "$skipped" ] && echo "⚠ Skipped (PATH already has a command of the same name, not overwritten):$skipped — if you want this version, remove the existing one by hand first and reinstall"

# Drop in example configs (do not overwrite existing ones; no throttling/ACL is enabled by default)
[ -f "$BUSHOME/config.example" ]     || cp "$SKILLDIR/examples/config"     "$BUSHOME/config.example"
[ -f "$BUSHOME/policy.tsv.example" ] || cp "$SKILLDIR/examples/policy.tsv" "$BUSHOME/policy.tsv.example"

echo "✅ Installed: 11 commands → $BINDIR; runtime root → $BUSHOME"
case ":$PATH:" in *":$BINDIR:"*) :;; *) echo "⚠ $BINDIR is not in PATH, please add it";; esac

cat <<EOF

—— Remaining activation steps for you to do by hand (this script deliberately leaves these alone) ——

1) [Receive hook] Merge the following into the top level of ~/.claude/settings.json (keep your existing fields, just add hooks):
   "hooks": {
     "SessionStart": [ { "hooks": [ { "type": "command",
        "command": "cc-register >/dev/null 2>&1 || true" } ] } ],
     "Stop": [ { "hooks": [ { "type": "command", "command": "cc-bus-stop-hook" } ] } ]
   }
   Validate with: jq . ~/.claude/settings.json

2) [Start CC]: just start \`claude\` normally in a tmux pane — identity is automatically = the tmux session name (e.g. shengwu_cc),
   no CC_BUS_ID needed. To distinguish multiple CCs within the same session, tag each pane:  tmux set -p @cc_id <name>
   (check who you are: cc-whoami; see who's online: cc-list)

3) [Optional: broker daemon] (works fine without it — when absent, cc-send automatically falls back to running the same pipeline itself)
   Manual foreground/background:  cc-busd start   (stop: cc-busd stop; status: cc-busd status)
   Or install it as a systemd --user service (auto-start on boot):
     mkdir -p ~/.config/systemd/user && cp "$SKILLDIR/examples/cc-busd.service" ~/.config/systemd/user/
     systemctl --user daemon-reload && systemctl --user enable --now cc-busd

4) [Optional: turn on routing policy] cp $BUSHOME/config.example $BUSHOME/config, then enable rate-limiting/ACL as needed (see the comments in the file).

Uninstall: remove the hooks section from settings.json; cc-busd stop; delete the symlinks in $BINDIR. The script itself is harmless to leave in place.
EOF
