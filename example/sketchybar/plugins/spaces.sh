#!/usr/bin/env bash
set -euo pipefail

if ! command -v sketchybar >/dev/null 2>&1; then
  exit 0
fi

SENDER="${SENDER:-}"

resolve_provider() {
  local provider="${1:-auto}"
  if [[ "$provider" == "auto" ]]; then
    if command -v yabai >/dev/null 2>&1; then
      provider="yabai"
    elif command -v aerospace >/dev/null 2>&1; then
      provider="aerospace"
    else
      provider=""
    fi
  fi
  printf "%s" "$provider"
}

provider="$(resolve_provider "${SPACES_PROVIDER:-auto}")"
if [[ -z "$provider" ]]; then
  exit 0
fi
export SPACES_PROVIDER="$provider"

cache_file="${SPACES_CACHE_FILE:-${TMPDIR:-/tmp}/sketchybar-spaces-items}"
item_prefix="${SPACES_ITEM_PREFIX:-space}"

fetch_entries() {
  python3 - <<'PY'
import json
import os
import re
import shutil
import subprocess
import sys

provider = os.environ.get("SPACES_PROVIDER", "auto").lower()
if provider == "auto":
    if shutil.which("yabai"):
        provider = "yabai"
    elif shutil.which("aerospace"):
        provider = "aerospace"
    else:
        sys.exit(0)

show_key = os.environ.get("SPACES_SHOW_KEY", "true").lower() == "true"
show_title = os.environ.get("SPACES_SHOW_WINDOW_TITLE", "true").lower() == "true"
show_empty = os.environ.get("SPACES_SHOW_EMPTY", "false").lower() == "true"
max_len = int(os.environ.get("SPACES_TITLE_MAX_LENGTH", "50"))
always_display = [
    item.strip()
    for item in os.environ.get("SPACES_ALWAYS_SHOW_APP_FOR", "").split(",")
    if item.strip()
]

def run(cmd):
    try:
        return subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""

def sanitize_space_id(space_id: str) -> str:
    return re.sub(r"[^A-Za-z0-9_-]", "_", space_id)

def app_abbr(app):
    if not app:
        return "?"
    words = [w for w in re.split(r"\s+", app) if w]
    if not words:
        return app[:1].upper()
    abbr = "".join(word[0] for word in words)
    return abbr[:2].upper()

def sort_key(space_id):
    return int(space_id) if space_id.isdigit() else space_id

spaces = []

if provider == "yabai":
    spaces_raw = run(["yabai", "-m", "query", "--spaces"])
    windows_raw = run(["yabai", "-m", "query", "--windows"])
    if not spaces_raw or not windows_raw:
        sys.exit(0)
    spaces_json = json.loads(spaces_raw)
    windows_json = json.loads(windows_raw)
    windows = [
        w for w in windows_json
        if not w.get("is-hidden") and not w.get("is-floating") and not w.get("is-sticky")
    ]
    space_map = {
        str(s["index"]): {
            "id": str(s["index"]),
            "focused": s.get("has-focus", False),
            "windows": [],
        }
        for s in spaces_json
    }
    for w in windows:
        space_id = str(w.get("space"))
        if space_id in space_map:
            space_map[space_id]["windows"].append({
                "id": w.get("id"),
                "app": w.get("app"),
                "title": w.get("title") or "",
                "focused": w.get("has-focus", False),
                "stack_index": w.get("stack-index", 0),
            })
    for space in space_map.values():
        space["windows"].sort(key=lambda w: w.get("stack_index", 0))
    spaces = list(space_map.values())
elif provider == "aerospace":
    spaces_raw = run([
        "aerospace", "list-workspaces", "--all", "--json",
    ])
    focused_raw = run([
        "aerospace", "list-workspaces", "--focused", "--json",
    ])
    windows_raw = run([
        "aerospace", "list-windows", "--all", "--json", "--format",
        "%{window-id} %{app-name} %{window-title} %{workspace}",
    ])
    focused_windows_raw = run([
        "aerospace", "list-windows", "--focused", "--json",
    ])
    if not spaces_raw or not focused_raw or not windows_raw or not focused_windows_raw:
        sys.exit(0)
    spaces_json = json.loads(spaces_raw)
    focused_spaces = json.loads(focused_raw)
    focused_space_id = focused_spaces[0]["workspace"] if focused_spaces else None
    windows_json = json.loads(windows_raw)
    focused_windows = json.loads(focused_windows_raw)
    focused_window_id = focused_windows[0].get("window-id") if focused_windows else None
    space_map = {
        s["workspace"]: {
            "id": s["workspace"],
            "focused": s["workspace"] == focused_space_id,
            "windows": [],
        }
        for s in spaces_json
    }
    for w in windows_json:
        workspace = w.get("workspace") or focused_space_id
        if not workspace:
            continue
        if workspace not in space_map:
            space_map[workspace] = {
                "id": workspace,
                "focused": workspace == focused_space_id,
                "windows": [],
            }
        space_map[workspace]["windows"].append({
            "id": w.get("window-id"),
            "app": w.get("app-name"),
            "title": w.get("window-title") or "",
            "focused": w.get("window-id") == focused_window_id,
        })
    for space in space_map.values():
        space["windows"].sort(key=lambda w: w.get("id") or 0)
    spaces = list(space_map.values())
else:
    sys.exit(0)

if not show_empty:
    spaces = [s for s in spaces if s["windows"]]

spaces.sort(key=lambda s: sort_key(s["id"]))

def focused_window(space):
    for window in space["windows"]:
        if window.get("focused"):
            return window
    return None

icon_gap = int(os.environ.get("SPACES_ICON_GAP", "2"))
icon_separator = " " * max(icon_gap, 1)

for space in spaces:
    parts = []
    if show_key:
        parts.append(space["id"])
    icons = [app_abbr(w.get("app")) for w in space["windows"]]
    if icons:
        parts.append(icon_separator.join(icons))
    if show_title:
        focused = focused_window(space)
        if focused:
            app = focused.get("app") or ""
            title = focused.get("title") or ""
            same_app_count = sum(1 for w in space["windows"] if w.get("app") == app)
            if app and (same_app_count <= 1 or app in always_display):
                display = app
            else:
                display = title or app
            if display:
                if len(display) > max_len:
                    display = display[:max_len] + "..."
                parts.append(display)
    label = "  ".join([p for p in parts if p])
    print(f"{space['id']}\t{sanitize_space_id(space['id'])}\t{1 if space.get('focused') else 0}\t{label}")
PY
}

clear_items() {
  local old_items="$1"
  if [[ -n "$old_items" ]]; then
    while IFS= read -r item; do
      [[ -z "$item" ]] && continue
      sketchybar --remove "$item" >/dev/null 2>&1 || true
    done <<< "$old_items"
  fi
  printf "" > "$cache_file"
}

update_items() {
  local entries old_items new_items
  entries="$(fetch_entries)"

  old_items=""
  if [[ -f "$cache_file" ]]; then
    old_items="$(cat "$cache_file")"
  fi

  if [[ -z "$entries" ]]; then
    clear_items "$old_items"
    return
  fi

  new_items=""
  while IFS=$'\t' read -r space_id safe_id focused label; do
    local item label_safe click_script escaped_space_id
    item="${item_prefix}.${safe_id}"
    new_items+="${item}"$'\n'

    label_safe="${label//$'\n'/ }"
    click_script=""
    escaped_space_id="$(printf '%q' "$space_id")"
    if [[ "$provider" == "yabai" ]]; then
      click_script="yabai -m space --focus ${escaped_space_id}"
    elif [[ "$provider" == "aerospace" ]]; then
      click_script="aerospace workspace ${escaped_space_id}"
    fi

    if ! grep -Fxq "$item" <<< "$old_items"; then
      sketchybar --add item "$item" left --set "$item"
    fi

    sketchybar --set "$item" \
      label="$label_safe" \
      label.font="${SPACES_FONT:-SF Pro:Semibold:13}" \
      label.color="${SPACES_TEXT_COLOR:-0xE6000000}" \
      label.padding_left="${SPACES_LABEL_PADDING:-10}" \
      label.padding_right="${SPACES_LABEL_PADDING:-10}" \
      background.height="${SPACES_BACKGROUND_HEIGHT:-28}" \
      background.corner_radius="${SPACES_CORNER_RADIUS:-8}" \
      background.drawing=on \
      background.shadow.drawing=on \
      background.shadow.radius=2 \
      background.shadow.color="${SPACES_SHADOW_COLOR:-0x33000000}" \
      padding_left=0 \
      padding_right=0 \
      click_script="$click_script"

    if [[ "$focused" == "1" ]]; then
      sketchybar --animate sin 12 --set "$item" \
        background.color="${SPACES_ACTIVE_COLOR:-0xCCFFFFFF}" \
        label.color="${SPACES_TEXT_COLOR_FOCUSED:-0xE6000000}"
    else
      sketchybar --set "$item" \
        background.color="${SPACES_INACTIVE_COLOR:-0x66FFFFFF}"
    fi
  done <<< "$entries"

  if [[ -n "$old_items" ]]; then
    while IFS= read -r item; do
      [[ -z "$item" ]] && continue
      if ! grep -Fxq "$item" <<< "$new_items"; then
        sketchybar --remove "$item" >/dev/null 2>&1 || true
      fi
    done <<< "$old_items"
  fi

  printf "%s" "$new_items" > "$cache_file"
}

case "$SENDER" in
  "" | "routine" | "forced" | "space_change" | "front_app_switched" | "window_focus" | "display_change")
    update_items
    ;;
  *)
    exit 0
    ;;
esac
