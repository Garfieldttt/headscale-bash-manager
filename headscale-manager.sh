#!/usr/bin/env bash
# headscale-manager — Headscale TUI (runs directly on the server)

TITLE="Headscale Manager"
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

LOG=/tmp/hm.log
: > "$LOG"
log() { printf '[%s] %s\n' "$(date +%T)" "$*" >> "$LOG" 2>/dev/null; }
export -f log LOG

log "headscale-manager: start PID=$$"

offer_copy() {
  local label="$1" value="$2"
  [[ -z "$value" ]] && return
  local kw=$(( ${#value} + 8 ))
  [[ $kw -gt $W ]] && kw=$W
  dialog --title "$TITLE — $label" \
    --inputbox "\nShift+double-click to select all, then Ctrl+Shift+C to copy:" 9 $kw "$value" 2>/dev/null
}

extract_key() {
  printf '%s' "$1" | grep -oE '[A-Za-z0-9_:/-]{32,}' | head -1
}

resize_dims() {
  H=$(tput lines 2>/dev/null); [[ -z "$H" || "$H" -lt 10 ]] && H=24
  W=$(tput cols  2>/dev/null); [[ -z "$W" || "$W" -lt 40 ]] && W=80
  [[ "$W" -gt 130 ]] && W=130
}
resize_dims
trap 'resize_dims' SIGWINCH

# ─── JSON helpers ────────────────────────────────────────────────────────────

nodes_json()   { headscale nodes list      -o json </dev/null 2>&1; }
users_json()   { headscale users list      -o json </dev/null 2>&1; }
keys_json()    { headscale preauthkeys list -o json </dev/null 2>&1; }
apikeys_json() { headscale apikeys list    -o json </dev/null 2>&1; }

parse_nodes_menu() {
  log "parse_nodes_menu: start"
  local json; json=$(nodes_json)
  local rc=$?
  log "parse_nodes_menu: nodes_json rc=$rc, bytes=${#json}"
  if [[ $rc -ne 0 ]] || [[ -z "$json" ]]; then
    log "parse_nodes_menu: empty/error output"
    return 1
  fi
  printf '%s\n' "$json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for n in data:
    online = '●' if n.get('online') else '○'
    ip = n['ip_addresses'][0] if n.get('ip_addresses') else '-'
    label = f\"{online} {n['given_name']:<20} {n['user']['name']:<28} {ip}\"
    print(n['id'])
    print(label)
" 2>/dev/null
  log "parse_nodes_menu: done"
}

parse_users_menu() {
  users_json | python3 -c "
import json, sys
for u in json.load(sys.stdin):
    print(u['id'])
    print(u['name'])
"
}

parse_users_name_menu() {
  users_json | python3 -c "
import json, sys
for u in json.load(sys.stdin):
    print(u['name'])
    print(u['name'])
"
}

parse_keys_menu() {
  keys_json | python3 -c "
import json, sys, datetime
def fmt(ts):
    try: return datetime.datetime.fromtimestamp(ts).strftime('%Y-%m-%d %H:%M')
    except: return '-'
for k in json.load(sys.stdin):
    exp  = fmt(k.get('expiration', {}).get('seconds', 0))
    used = 'used' if k.get('used') else '----'
    reu  = 'reu'  if k.get('reusable') else '---'
    label = f\"{k['user']['name']:<28} {exp:<17} {used}  {reu}\"
    print(k['id'])
    print(label)
"
}

parse_apikeys_menu() {
  apikeys_json | python3 -c "
import json, sys, datetime
def fmt(ts):
    try: return datetime.datetime.fromtimestamp(ts).strftime('%Y-%m-%d %H:%M')
    except: return '-'
for k in json.load(sys.stdin):
    exp = fmt(k.get('expiration', {}).get('seconds', 0))
    print(k['id'])
    print(f\"{k['prefix']:<14} expires: {exp}\")
"
}

# ─── Selectors ───────────────────────────────────────────────────────────────
# All selectors write the result into $TMPFILE and return 0/1.
# Never call with $(...) — dialog needs a free stderr/tty for rendering.
# Caller pattern: select_xxx "..." || return; local id; id=$(cat "$TMPFILE")

select_node() {
  log "select_node: start prompt='$1'"
  local prompt="${1:-Select node:}"
  local -a items
  readarray -t items < <(parse_nodes_menu)
  log "select_node: items=${#items[@]}"
  [[ ${#items[@]} -eq 0 ]] && { dialog --title "$TITLE" --msgbox "\nNo nodes found." 7 $W; return 1; }
  : > "$TMPFILE"
  dialog --title "$TITLE" --menu "\n$prompt" $H $W 14 "${items[@]}" 2>"$TMPFILE"
  local rc=$?; log "select_node: dialog rc=$rc r=$(cat "$TMPFILE")"
  [[ $rc -ne 0 ]] && return 1
  [[ -z "$(cat "$TMPFILE")" ]] && return 1
  return 0
}

select_user_id() {
  local prompt="${1:-Select user:}"
  local -a items
  readarray -t items < <(parse_users_menu)
  [[ ${#items[@]} -eq 0 ]] && { dialog --title "$TITLE" --msgbox "\nNo users found." 7 $W; return 1; }
  : > "$TMPFILE"
  dialog --title "$TITLE" --menu "\n$prompt" $H $W 10 "${items[@]}" 2>"$TMPFILE" || return 1
  [[ -z "$(cat "$TMPFILE")" ]] && return 1
  return 0
}

select_user_name() {
  local prompt="${1:-Select user:}"
  local -a items
  readarray -t items < <(parse_users_name_menu)
  [[ ${#items[@]} -eq 0 ]] && { dialog --title "$TITLE" --msgbox "\nNo users found." 7 $W; return 1; }
  : > "$TMPFILE"
  dialog --title "$TITLE" --menu "\n$prompt" $H $W 10 "${items[@]}" 2>"$TMPFILE" || return 1
  [[ -z "$(cat "$TMPFILE")" ]] && return 1
  return 0
}

select_key() {
  local prompt="${1:-Select pre-auth key:}"
  local -a items
  readarray -t items < <(parse_keys_menu)
  [[ ${#items[@]} -eq 0 ]] && { dialog --title "$TITLE" --msgbox "\nNo keys found." 7 $W; return 1; }
  : > "$TMPFILE"
  dialog --title "$TITLE" --menu "\n$prompt" $H $W 10 "${items[@]}" 2>"$TMPFILE" || return 1
  [[ -z "$(cat "$TMPFILE")" ]] && return 1
  return 0
}

select_apikey() {
  local prompt="${1:-Select API key:}"
  local -a items
  readarray -t items < <(parse_apikeys_menu)
  [[ ${#items[@]} -eq 0 ]] && { dialog --title "$TITLE" --msgbox "\nNo API keys found." 7 $W; return 1; }
  : > "$TMPFILE"
  dialog --title "$TITLE" --menu "\n$prompt" $H $W 10 "${items[@]}" 2>"$TMPFILE" || return 1
  [[ -z "$(cat "$TMPFILE")" ]] && return 1
  return 0
}

# ─── Nodes ───────────────────────────────────────────────────────────────────

nodes_list() {
  local out
  out=$(nodes_json | python3 -c "
import json, sys, datetime
def fmt(ts):
    try: return datetime.datetime.fromtimestamp(ts).strftime('%Y-%m-%d %H:%M')
    except: return '-'
nodes = json.load(sys.stdin)
print(f\"{'ID':<4} {'St'} {'Name':<22} {'User':<28} {'IP':<16} {'Last seen'}\")
print('-' * 88)
for n in nodes:
    online = '●' if n.get('online') else '○'
    ip = n['ip_addresses'][0] if n.get('ip_addresses') else '-'
    last = fmt(n.get('last_seen', {}).get('seconds', 0))
    ra = len(n.get('available_routes') or [])
    rk = len(n.get('approved_routes') or [])
    rinfo = f' [{rk}/{ra}r]' if ra else ''
    print(f\"{n['id']:<4} {online}  {n['given_name']:<22} {n['user']['name']:<28} {ip:<16} {last}{rinfo}\")
") || { dialog --title "$TITLE" --msgbox "\nError fetching nodes." 7 $W; return; }
  local tmp; tmp=$(mktemp)
  printf "%s" "$out" > "$tmp"
  dialog --title "$TITLE — Nodes" --scrolltext --textbox "$tmp" $H $W
  rm -f "$tmp"
}

nodes_rename() {
  select_node "Select node to rename:" || return
  local node_id; node_id=$(cat "$TMPFILE")
  local node_name
  node_name=$(nodes_json | python3 -c "
import json,sys
for n in json.load(sys.stdin):
    if str(n['id']) == '${node_id}': print(n['given_name']); break
" 2>/dev/null)
  dialog --title "$TITLE" --inputbox "\nNew name for '$node_name':" 9 $W "" 2>"$TMPFILE" || return
  local newname; newname=$(cat "$TMPFILE")
  [[ -z "$newname" ]] && return
  local out; out=$(headscale nodes rename -i "$node_id" "$newname" --force </dev/null 2>&1)
  dialog --title "$TITLE" --msgbox "\n$out" 9 $W
}

nodes_expire() {
  select_node "Select node to expire:" || return
  local node_id; node_id=$(cat "$TMPFILE")
  dialog --title "$TITLE" --yesno "\nExpire node #$node_id?\nThe node will need to re-authenticate." 8 $W || return
  local out; out=$(headscale nodes expire -i "$node_id" --force </dev/null 2>&1)
  dialog --title "$TITLE" --msgbox "\n$out" 9 $W
}

nodes_delete() {
  log "nodes_delete: start"
  select_node "Select node to delete:" || return
  local node_id; node_id=$(cat "$TMPFILE")
  log "nodes_delete: node_id='$node_id'"
  local node_name
  node_name=$(nodes_json | python3 -c "
import json,sys
for n in json.load(sys.stdin):
    if str(n['id']) == '${node_id}': print(n['given_name']); break
" 2>/dev/null)
  dialog --title "$TITLE" --yesno "\nPermanently DELETE node '${node_name}' (#${node_id})?\nThis cannot be undone!" 8 $W || return
  local out; out=$(headscale nodes delete -i "$node_id" --force </dev/null 2>&1)
  log "nodes_delete: done out='$out'"
  dialog --title "$TITLE" --msgbox "\n$out" 9 $W
}

nodes_routes() {
  select_node "Select node for route management:" || return
  local node_id; node_id=$(cat "$TMPFILE")

  local route_data
  route_data=$(nodes_json | python3 -c "
import json,sys
for n in json.load(sys.stdin):
    if str(n['id']) == '${node_id}':
        avail    = n.get('available_routes') or []
        approved = n.get('approved_routes') or []
        seen = []
        for r in avail + approved:
            if r not in seen:
                seen.append(r)
        for r in seen:
            print(r, 'on' if r in approved else 'off')
        break
")

  if [[ -z "$route_data" ]]; then
    dialog --title "$TITLE" --msgbox "\nNo routes available for node #$node_id." 7 $W
    return
  fi

  local -a items=()
  while read -r route state; do
    items+=("$route" "$route" "$state")
  done <<< "$route_data"

  dialog --title "$TITLE" --checklist "\nEnable routes for node #$node_id:" $H $W 10 "${items[@]}" 2>"$TMPFILE" || return
  local selected; selected=$(cat "$TMPFILE" | tr -d '"' | tr ' ' ',')
  local out; out=$(headscale nodes approve-routes -i "$node_id" -r "$selected" --force </dev/null 2>&1)
  dialog --title "$TITLE" --msgbox "\n$out" 9 $W
}

nodes_tags() {
  select_node "Select node to set tags:" || return
  local node_id; node_id=$(cat "$TMPFILE")
  local current
  current=$(nodes_json | python3 -c "
import json,sys
for n in json.load(sys.stdin):
    if str(n['id']) == '${node_id}':
        tags = []
        for key in ('valid_tags','forced_tags','invalid_tags'):
            tags += [t.replace('tag:','') for t in (n.get(key) or [])]
        print(','.join(dict.fromkeys(tags)))
        break
")
  dialog --title "$TITLE" --inputbox "\nTags for node #$node_id (comma-separated, without 'tag:'):\nCurrent: ${current:--}" 10 $W "$current" 2>"$TMPFILE" || return
  local tagstr; tagstr=$(cat "$TMPFILE")

  local -a tag_args=()
  if [[ -n "$tagstr" ]]; then
    IFS=',' read -ra tags <<< "$tagstr"
    for t in "${tags[@]}"; do
      t="${t// /}"
      [[ -n "$t" ]] && tag_args+=("-t" "tag:$t")
    done
  fi
  local out; out=$(headscale nodes tag -i "$node_id" "${tag_args[@]}" --force </dev/null 2>&1)
  dialog --title "$TITLE" --msgbox "\n$out" 9 $W
}

nodes_copy_ip() {
  select_node "Select node to copy IP:" || return
  local node_id; node_id=$(cat "$TMPFILE")
  local ip
  ip=$(nodes_json | python3 -c "
import json,sys
for n in json.load(sys.stdin):
    if str(n['id']) == '${node_id}':
        print(n['ip_addresses'][0] if n.get('ip_addresses') else '')
        break
" 2>/dev/null)
  [[ -z "$ip" ]] && { dialog --title "$TITLE" --msgbox "\nNo IP found for node #$node_id." 7 $W; return; }
  offer_copy "node IP" "$ip"
}

nodes_register() {
  local server_url
  server_url=$(grep -E '^server_url:' /etc/headscale/config.yaml 2>/dev/null | awk '{print $2}')
  dialog --title "$TITLE — Register Node" --msgbox "\
\nRun on the client:\n\
  tailscale login --login-server ${server_url:-<server_url>}\n\
\n\
A URL will open in the browser. Copy the part\n\
  nodekey:...\n\
from the URL and paste it in the next dialog." 13 $W || return
  dialog --title "$TITLE" --inputbox "\nPaste node key (Ctrl+Shift+V), format: nodekey:...:" 9 $W "" 2>"$TMPFILE" || return
  local nodekey; nodekey=$(cat "$TMPFILE")
  [[ -z "$nodekey" ]] && return
  select_user_name "Select user for new node:" || return
  local username; username=$(cat "$TMPFILE")
  local out; out=$(headscale nodes register -u "$username" -k "$nodekey" </dev/null 2>&1)
  dialog --title "$TITLE" --msgbox "\n$out" 10 $W
}

nodes_routes_overview() {
  local out
  out=$(nodes_json | python3 -c "
import json,sys
nodes = json.load(sys.stdin)
has_routes = [n for n in nodes if n.get('available_routes')]
if not has_routes:
    print('No nodes with routes.')
else:
    print(f\"{'ID':<4} {'Name':<22} {'Available':<38} {'Approved'}\")
    print('-' * 90)
    for n in has_routes:
        avail    = ', '.join(n.get('available_routes') or [])
        approved = ', '.join(n.get('approved_routes') or ['-'])
        print(f\"{n['id']:<4} {n['given_name']:<22} {avail:<38} {approved}\")
")
  local tmp; tmp=$(mktemp)
  printf "%s" "$out" > "$tmp"
  dialog --title "$TITLE — Routes Overview" --scrolltext --textbox "$tmp" $H $W
  rm -f "$tmp"
}

menu_nodes() {
  while true; do
    dialog --title "$TITLE — Nodes" --menu "\nWhat would you like to do?" 20 $W 10 \
      "1" "List nodes" \
      "2" "Routes overview" \
      "3" "Rename node" \
      "4" "Expire node" \
      "5" "Delete node" \
      "6" "Manage routes" \
      "7" "Set tags" \
      "8" "Register node" \
      "9" "Copy node IP" \
      "0" "Back" \
      2>"$TMPFILE" || return
    case $(cat "$TMPFILE") in
      1) nodes_list ;;
      2) nodes_routes_overview ;;
      3) nodes_rename ;;
      4) nodes_expire ;;
      5) nodes_delete ;;
      6) nodes_routes ;;
      7) nodes_tags ;;
      8) nodes_register ;;
      9) nodes_copy_ip ;;
      0) return ;;
    esac
  done
}

# ─── Users ───────────────────────────────────────────────────────────────────

users_list() {
  local out
  out=$(users_json | python3 -c "
import json, sys, datetime
def fmt(ts):
    try: return datetime.datetime.fromtimestamp(ts).strftime('%Y-%m-%d')
    except: return '-'
users = json.load(sys.stdin)
print(f\"{'ID':<6} {'Name':<36} {'Created'}\")
print('-' * 56)
for u in users:
    created = fmt(u.get('created_at', {}).get('seconds', 0))
    print(f\"{u['id']:<6} {u['name']:<36} {created}\")
") || { dialog --title "$TITLE" --msgbox "\nError fetching users." 7 $W; return; }
  local tmp; tmp=$(mktemp)
  printf "%s" "$out" > "$tmp"
  dialog --title "$TITLE — Users" --scrolltext --textbox "$tmp" $H $W
  rm -f "$tmp"
}

users_create() {
  dialog --title "$TITLE" --inputbox "\nUsername (e.g. name@example.com):" 8 $W "" 2>"$TMPFILE" || return
  local name; name=$(cat "$TMPFILE")
  [[ -z "$name" ]] && return
  local out; out=$(headscale users create "$name" </dev/null 2>&1)
  dialog --title "$TITLE" --msgbox "\n$out" 9 $W
}

users_rename() {
  select_user_id "Select user to rename:" || return
  local user_id; user_id=$(cat "$TMPFILE")
  dialog --title "$TITLE" --inputbox "\nNew name for user #$user_id:" 8 $W "" 2>"$TMPFILE" || return
  local newname; newname=$(cat "$TMPFILE")
  [[ -z "$newname" ]] && return
  local out; out=$(headscale users rename -i "$user_id" -r "$newname" --force </dev/null 2>&1)
  dialog --title "$TITLE" --msgbox "\n$out" 9 $W
}

users_delete() {
  select_user_id "Select user to delete:" || return
  local user_id; user_id=$(cat "$TMPFILE")
  dialog --title "$TITLE" --yesno "\nPermanently DELETE user #$user_id?" 7 $W || return
  local out; out=$(headscale users destroy -i "$user_id" --force </dev/null 2>&1)
  dialog --title "$TITLE" --msgbox "\n$out" 9 $W
}

menu_users() {
  while true; do
    dialog --title "$TITLE — Users" --menu "\nWhat would you like to do?" 14 $W 5 \
      "1" "List users" \
      "2" "Create user" \
      "3" "Rename user" \
      "4" "Delete user" \
      "0" "Back" \
      2>"$TMPFILE" || return
    case $(cat "$TMPFILE") in
      1) users_list ;;
      2) users_create ;;
      3) users_rename ;;
      4) users_delete ;;
      0) return ;;
    esac
  done
}

# ─── Pre-Auth Keys ───────────────────────────────────────────────────────────

preauthkeys_list() {
  local out
  out=$(keys_json | python3 -c "
import json, sys, datetime, time
def fmt(ts):
    try: return datetime.datetime.fromtimestamp(ts).strftime('%Y-%m-%d %H:%M')
    except: return '-'
now = time.time()
keys = json.load(sys.stdin)
print(f\"{'ID':<4} {'User':<28} {'Expires':<18} {'Status':<10} {'Reu':<4} {'Eph'}\")
print('-' * 72)
for k in keys:
    exp_ts = k.get('expiration', {}).get('seconds', 0)
    exp    = fmt(exp_ts)
    reu    = 'yes' if k.get('reusable')  else 'no'
    eph    = 'yes' if k.get('ephemeral') else 'no'
    if exp_ts and exp_ts < now:
        status = 'expired'
    elif k.get('used') and not k.get('reusable'):
        status = 'exhausted'
    else:
        status = 'active'
    print(f\"{k['id']:<4} {k['user']['name']:<28} {exp:<18} {status:<10} {reu:<4} {eph}\")
") || { dialog --title "$TITLE" --msgbox "\nError fetching keys." 7 $W; return; }
  local tmp; tmp=$(mktemp)
  printf "%s" "$out" > "$tmp"
  dialog --title "$TITLE — Pre-Auth Keys" --scrolltext --textbox "$tmp" $H $W
  rm -f "$tmp"
}

preauthkeys_create() {
  select_user_id "Select user for new pre-auth key:" || return
  local user_id; user_id=$(cat "$TMPFILE")
  dialog --title "$TITLE" --inputbox "\nExpiration (e.g. 1h, 24h, 7d):" 8 $W "24h" 2>"$TMPFILE" || return
  local expiry; expiry=$(cat "$TMPFILE")
  [[ -z "$expiry" ]] && expiry="24h"

  local -a extra_args=()
  dialog --title "$TITLE" --yesno "\nMake key reusable?" 7 $W && extra_args+=("--reusable")
  dialog --title "$TITLE" --yesno "\nEphemeral node (deleted after disconnect)?" 7 $W && extra_args+=("--ephemeral")

  local out; out=$(headscale preauthkeys create -u "$user_id" -e "$expiry" "${extra_args[@]}" </dev/null 2>&1)
  dialog --title "$TITLE" --msgbox "\nNew pre-auth key:\n\n$out" 13 $W
  offer_copy "pre-auth key" "$(extract_key "$out")"
}

preauthkeys_expire() {
  select_key "Select key to expire:" || return
  local key_id; key_id=$(cat "$TMPFILE")
  local out; out=$(headscale preauthkeys expire -i "$key_id" </dev/null 2>&1)
  dialog --title "$TITLE" --msgbox "\n$out" 9 $W
}

preauthkeys_delete() {
  select_key "Select key to delete:" || return
  local key_id; key_id=$(cat "$TMPFILE")
  dialog --title "$TITLE" --yesno "\nDelete pre-auth key #$key_id?" 7 $W || return
  local out; out=$(headscale preauthkeys delete -i "$key_id" </dev/null 2>&1)
  dialog --title "$TITLE" --msgbox "\n$out" 9 $W
}

menu_preauthkeys() {
  while true; do
    dialog --title "$TITLE — Pre-Auth Keys" --menu "\nWhat would you like to do?" 14 $W 5 \
      "1" "List keys" \
      "2" "Create key" \
      "3" "Expire key" \
      "4" "Delete key" \
      "0" "Back" \
      2>"$TMPFILE" || return
    case $(cat "$TMPFILE") in
      1) preauthkeys_list ;;
      2) preauthkeys_create ;;
      3) preauthkeys_expire ;;
      4) preauthkeys_delete ;;
      0) return ;;
    esac
  done
}

# ─── API Keys ────────────────────────────────────────────────────────────────

apikeys_list() {
  local out
  out=$(apikeys_json | python3 -c "
import json, sys, datetime
def fmt(ts):
    try: return datetime.datetime.fromtimestamp(ts).strftime('%Y-%m-%d %H:%M')
    except: return '-'
keys = json.load(sys.stdin)
print(f\"{'ID':<4} {'Prefix':<14} {'Expires'}\")
print('-' * 40)
for k in keys:
    exp = fmt(k.get('expiration', {}).get('seconds', 0))
    print(f\"{k['id']:<4} {k['prefix']:<14} {exp}\")
") || { dialog --title "$TITLE" --msgbox "\nError fetching API keys." 7 $W; return; }
  local tmp; tmp=$(mktemp)
  printf "%s" "$out" > "$tmp"
  dialog --title "$TITLE — API Keys" --scrolltext --textbox "$tmp" 14 $W
  rm -f "$tmp"
}

apikeys_create() {
  dialog --title "$TITLE" --inputbox "\nExpiration for new API key (e.g. 90d, 1y):" 8 $W "90d" 2>"$TMPFILE" || return
  local expiry; expiry=$(cat "$TMPFILE")
  [[ -z "$expiry" ]] && expiry="90d"
  local out; out=$(headscale apikeys create -e "$expiry" </dev/null 2>&1)
  dialog --title "$TITLE" --msgbox "\nNew API key:\n\n$out\n\nSave it now — it will not be shown again!" 13 $W
  offer_copy "API key" "$(extract_key "$out")"
}

apikeys_expire() {
  select_apikey "Select API key to expire:" || return
  local key_id; key_id=$(cat "$TMPFILE")
  local out; out=$(headscale apikeys expire -i "$key_id" </dev/null 2>&1)
  dialog --title "$TITLE" --msgbox "\n$out" 9 $W
}

apikeys_delete() {
  select_apikey "Select API key to delete:" || return
  local key_id; key_id=$(cat "$TMPFILE")
  dialog --title "$TITLE" --yesno "\nDelete API key #$key_id?" 7 $W || return
  local out; out=$(headscale apikeys delete -i "$key_id" </dev/null 2>&1)
  dialog --title "$TITLE" --msgbox "\n$out" 9 $W
}

menu_apikeys() {
  while true; do
    dialog --title "$TITLE — API Keys" --menu "\nWhat would you like to do?" 14 $W 5 \
      "1" "List API keys" \
      "2" "Create API key" \
      "3" "Expire API key" \
      "4" "Delete API key" \
      "0" "Back" \
      2>"$TMPFILE" || return
    case $(cat "$TMPFILE") in
      1) apikeys_list ;;
      2) apikeys_create ;;
      3) apikeys_expire ;;
      4) apikeys_delete ;;
      0) return ;;
    esac
  done
}

# ─── Policy ──────────────────────────────────────────────────────────────────

policy_view() {
  local out; out=$(headscale policy get 2>&1)
  local tmp; tmp=$(mktemp)
  printf "%s" "$out" > "$tmp"
  dialog --title "$TITLE — ACL Policy (read-only)" --scrolltext --textbox "$tmp" $H $W
  rm -f "$tmp"
}

policy_edit() {
  local current; current=$(headscale policy get 2>&1)
  if [[ "$current" == *"error"* ]] || [[ "$current" == *"Error"* ]]; then
    dialog --title "$TITLE" --msgbox "\nFailed to load policy:\n\n$current" 12 $W
    return
  fi

  local edit_tmp; edit_tmp=$(mktemp --suffix=.json)
  printf "%s" "$current" > "$edit_tmp"

  dialog --title "$TITLE — Edit ACL Policy (HuJSON)" --editbox "$edit_tmp" $H $W 2>"$TMPFILE" || { rm -f "$edit_tmp"; return; }
  cat "$TMPFILE" > "$edit_tmp"

  dialog --title "$TITLE" --yesno "\nSave and apply ACL policy?" 7 $W || { rm -f "$edit_tmp"; return; }

  local out; out=$(headscale policy set -f "$edit_tmp" </dev/null 2>&1)
  rm -f "$edit_tmp"
  dialog --title "$TITLE" --msgbox "\n$out" 10 $W
}

menu_policy() {
  while true; do
    dialog --title "$TITLE — ACL Policy" --menu "\nWhat would you like to do?" 12 $W 3 \
      "1" "View policy" \
      "2" "Edit policy" \
      "0" "Back" \
      2>"$TMPFILE" || return
    case $(cat "$TMPFILE") in
      1) policy_view ;;
      2) policy_edit ;;
      0) return ;;
    esac
  done
}

# ─── Health ──────────────────────────────────────────────────────────────────

show_health() {
  local out
  out=$(headscale health -o json 2>&1 | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for k, v in data.items():
        status = '● OK  ' if v else '○ FAIL'
        print(f'{status}  {k}')
except Exception:
    print('No response from server')
")
  dialog --title "$TITLE — Health" --msgbox "\n$out" 10 $W
}

# ─── Setup ───────────────────────────────────────────────────────────────────

check_deps() {
  local missing=()
  command -v dialog    &>/dev/null || missing+=("dialog")
  command -v headscale &>/dev/null || missing+=("headscale")
  command -v python3   &>/dev/null || missing+=("python3")
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: missing dependencies: ${missing[*]}" >&2
    [[ " ${missing[*]} " == *" dialog "* ]] && echo "  apt install dialog" >&2
    exit 1
  fi
}

# ─── Main menu ───────────────────────────────────────────────────────────────

main() {
  check_deps
  while true; do
    dialog --title "$TITLE" \
      --menu "\nHeadscale $(headscale version 2>/dev/null | head -1)" 17 $W 7 \
      "1" "Manage nodes" \
      "2" "Manage users" \
      "3" "Manage pre-auth keys" \
      "4" "Manage API keys" \
      "5" "ACL policy" \
      "6" "Health check" \
      "0" "Exit" \
      2>"$TMPFILE" || break
    case $(cat "$TMPFILE") in
      1) menu_nodes ;;
      2) menu_users ;;
      3) menu_preauthkeys ;;
      4) menu_apikeys ;;
      5) menu_policy ;;
      6) show_health ;;
      0) break ;;
    esac
  done
  clear
}

main
