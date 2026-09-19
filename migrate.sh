#!/usr/bin/env bash
# Migrates an install under an earlier plugin id ("user.local-ai-server" or
# "user.llama-server") to "sxy.local-ai-server".
#
# The plugin id appears in the bar layout in shell.json, so renaming the
# directory alone would drop the widget off the bar and require re-placing it
# by hand. This rewrites that reference in place, preserving the widget's
# position, and carries the saved settings (and slot KV caches) across.
#
# Safe to run more than once: it exits cleanly when there is nothing left to
# migrate. shell.json is backed up first; old state is copied, never moved.

set -euo pipefail

OLD_IDS=("user.local-ai-server" "user.llama-server")
NEW_ID="sxy.local-ai-server"
SHELL_JSON="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy"
NEW_STATE="$STATE_ROOT/$NEW_ID"
PLUGIN_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins"

migrated=0

# --- Settings state ------------------------------------------------------
# The newest earlier id wins. Copied rather than moved, so the old plugin
# keeps working if the user rolls back; reflinked where the filesystem allows,
# since the slot caches can run to gigabytes.
if [[ -d $NEW_STATE ]]; then
  echo "Settings already present at $NEW_STATE — left untouched."
else
  for old_id in "${OLD_IDS[@]}"; do
    old_state="$STATE_ROOT/$old_id"
    if [[ -d $old_state ]]; then
      cp -a --reflink=auto "$old_state" "$NEW_STATE"
      echo "Copied settings: $old_state -> $NEW_STATE"
      migrated=1
      break
    fi
  done
fi

# --- Bar layout ----------------------------------------------------------
if [[ ! -f $SHELL_JSON ]]; then
  echo "No shell.json at $SHELL_JSON — nothing to rewrite." >&2
else
  backup="$SHELL_JSON.bak.$(date +%Y%m%d%H%M%S)"
  cp "$SHELL_JSON" "$backup"

  # Rewritten with python rather than sed so the file is parsed as JSON and
  # a malformed edit can never be written back over a working config.
  status=0
  python3 - "$SHELL_JSON" "$NEW_ID" "${OLD_IDS[@]}" <<'PY' || status=$?
import json, sys

path, new_id, old_ids = sys.argv[1], sys.argv[2], set(sys.argv[3:])

with open(path) as fh:
    data = json.load(fh)

changed = 0

def walk(node):
    global changed
    if isinstance(node, dict):
        if node.get("id") in old_ids:
            node["id"] = new_id
            changed += 1
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)

walk(data)

if changed:
    with open(path, "w") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")

sys.exit(0 if changed else 3)
PY
  if [[ $status -eq 0 ]]; then
    echo "Rewrote bar layout id in $SHELL_JSON (backup: $backup)"
    migrated=1
  elif [[ $status -eq 3 ]]; then
    echo "No earlier plugin id in shell.json — nothing to rewrite."
    rm -f "$backup"
  else
    echo "Failed to rewrite $SHELL_JSON; restoring backup." >&2
    cp "$backup" "$SHELL_JSON"
    exit 1
  fi
fi

# --- Old plugin directories ----------------------------------------------
# Left in place deliberately: removing them is the user's call, and keeping
# them makes rolling back a one-line config edit rather than a reinstall.
for old_id in "${OLD_IDS[@]}"; do
  if [[ -d $PLUGIN_ROOT/$old_id ]]; then
    echo
    echo "An old copy of the plugin is still installed at:"
    echo "  $PLUGIN_ROOT/$old_id"
    echo "Remove it once the new one is working:"
    echo "  rm -rf $PLUGIN_ROOT/$old_id"
  fi
done

if [[ $migrated -eq 1 ]]; then
  echo
  echo "Migration done. Reload the shell to pick it up:"
  echo "  omarchy-shell shell rescanPlugins && omarchy restart shell"
else
  echo "Nothing to migrate."
fi
