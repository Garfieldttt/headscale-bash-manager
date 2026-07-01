#!/usr/bin/env bash
# headscale-manager — Headscale TUI (runs directly on the server)

TITLE="Headscale Manager"
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

CONFIG_FILE="/etc/headscale-manager.conf"
ACL_BACKUP_DIR="/etc/headscale/acl-backups"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

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
  log "parse_nodes_menu: start filter=${1:-all}"
  local json; json=$(nodes_json)
  local rc=$?
  log "parse_nodes_menu: nodes_json rc=$rc, bytes=${#json}"
  if [[ $rc -ne 0 ]] || [[ -z "$json" ]]; then
    log "parse_nodes_menu: empty/error output"
    return 1
  fi
  printf '%s\n' "$json" | python3 -c "
import json, sys
filter_mode = '${1:-all}'
data = json.load(sys.stdin)
for n in data:
    if filter_mode == 'routes' and not (n.get('available_routes') or n.get('approved_routes')):
        continue
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
  log "nodes_routes: start"
  local prompt="Select node for route management:"
  local -a items
  readarray -t items < <(parse_nodes_menu routes)
  [[ ${#items[@]} -eq 0 ]] && { dialog --title "$TITLE" --msgbox "\nNo nodes with routes found." 7 $W; return; }
  : > "$TMPFILE"
  dialog --title "$TITLE" --menu "\n$prompt" $H $W 14 "${items[@]}" 2>"$TMPFILE" || return
  [[ -z "$(cat "$TMPFILE")" ]] && return
  local node_id; node_id=$(cat "$TMPFILE")
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

nodes_details() {
  select_node "Select node to view:" || return
  local node_id; node_id=$(cat "$TMPFILE")
  local out
  out=$(nodes_json | python3 -c "
import json, sys, datetime
def fmt(ts):
    try: return datetime.datetime.fromtimestamp(ts).strftime('%Y-%m-%d %H:%M')
    except: return '-'
for n in json.load(sys.stdin):
    if str(n['id']) == '${node_id}':
        online = 'online' if n.get('online') else 'offline'
        ips    = ', '.join(n.get('ip_addresses') or ['-'])
        tags   = ', '.join((n.get('valid_tags') or []) + (n.get('forced_tags') or [])) or '-'
        avail  = ', '.join(n.get('available_routes') or ['-'])
        appr   = ', '.join(n.get('approved_routes')  or ['-'])
        print(f'Name:       {n[\"given_name\"]}')
        print(f'ID:         {n[\"id\"]}')
        print(f'Status:     {online}')
        print(f'User:       {n[\"user\"][\"name\"]}')
        print(f'IPs:        {ips}')
        print(f'Last seen:  {fmt(n.get(\"last_seen\", {}).get(\"seconds\", 0))}')
        print(f'Expiry:     {fmt(n.get(\"expiry\", {}).get(\"seconds\", 0))}')
        print(f'Tags:       {tags}')
        print(f'Routes avail: {avail}')
        print(f'Routes appr:  {appr}')
        break
" 2>/dev/null)
  dialog --title "$TITLE — Node Details" --msgbox "\n$out" 17 $W
}

nodes_list_online() {
  local out
  out=$(nodes_json | python3 -c "
import json, sys, datetime
def fmt(ts):
    try: return datetime.datetime.fromtimestamp(ts).strftime('%Y-%m-%d %H:%M')
    except: return '-'
nodes = [n for n in json.load(sys.stdin) if n.get('online')]
if not nodes:
    print('No nodes currently online.')
else:
    print(f\"{'ID':<4} {'Name':<22} {'User':<28} {'IP'}\")
    print('-' * 78)
    for n in nodes:
        ip = n['ip_addresses'][0] if n.get('ip_addresses') else '-'
        print(f\"{n['id']:<4} {'●'} {n['given_name']:<20} {n['user']['name']:<28} {ip}\")
") || { dialog --title "$TITLE" --msgbox "\nError fetching nodes." 7 $W; return; }
  local tmp; tmp=$(mktemp)
  printf "%s" "$out" > "$tmp"
  dialog --title "$TITLE — Online Nodes" --scrolltext --textbox "$tmp" $H $W
  rm -f "$tmp"
}

nodes_register() {
  local server_url
  server_url=$(grep -E '^server_url:' /etc/headscale/config.yaml 2>/dev/null | awk '{print $2}')
  dialog --title "$TITLE — Register Node" --msgbox "\
\nRun on the client:\n\
  tailscale login --login-server ${server_url:-<server_url>}\n\
\n\
A URL will open in the browser, e.g.\n\
  .../register/AUTH_ID\n\
Copy the full URL or just the AUTH_ID and paste it\n\
in the next dialog." 13 $W || return
  dialog --title "$TITLE" --inputbox "\nPaste the register URL or auth-id (Ctrl+Shift+V):" 9 $W "" 2>"$TMPFILE" || return
  local input; input=$(cat "$TMPFILE")
  [[ -z "$input" ]] && return
  local authid="${input%/}"; authid="${authid##*/}"
  select_user_name "Select user for new node:" || return
  local username; username=$(cat "$TMPFILE")
  local out; out=$(headscale auth register --auth-id "$authid" -u "$username" </dev/null 2>&1)
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
    dialog --title "$TITLE — Nodes" --menu "\nWhat would you like to do?" 24 $W 13 \
      "1" "List nodes" \
      "2" "Online nodes only" \
      "3" "Node details" \
      "4" "Routes overview" \
      "5" "Rename node" \
      "6" "Expire node" \
      "7" "Delete node" \
      "8" "Manage routes" \
      "9" "Set tags" \
      "a" "Register node" \
      "b" "Copy node IP" \
      "0" "Back" \
      2>"$TMPFILE" || return
    case $(cat "$TMPFILE") in
      1) nodes_list ;;
      2) nodes_list_online ;;
      3) nodes_details ;;
      4) nodes_routes_overview ;;
      5) nodes_rename ;;
      6) nodes_expire ;;
      7) nodes_delete ;;
      8) nodes_routes ;;
      9) nodes_tags ;;
      a) nodes_register ;;
      b) nodes_copy_ip ;;
      0) return ;;
    esac
  done
}

# ─── Users ───────────────────────────────────────────────────────────────────

users_list() {
  local tmp_nodes tmp_users; tmp_nodes=$(mktemp); tmp_users=$(mktemp)
  nodes_json > "$tmp_nodes"; users_json > "$tmp_users"
  local out
  out=$(python3 -c "
import json, sys, datetime
from collections import Counter
def fmt(ts):
    try: return datetime.datetime.fromtimestamp(ts).strftime('%Y-%m-%d')
    except: return '-'
nodes = json.load(open('$tmp_nodes'))
users = json.load(open('$tmp_users'))
counts = Counter(n['user']['name'] for n in nodes)
print(f\"{'ID':<6} {'Name':<36} {'Created':<12} {'Nodes'}\")
print('-' * 62)
for u in users:
    print(f\"{u['id']:<6} {u['name']:<36} {fmt(u.get('created_at',{}).get('seconds',0)):<12} {counts.get(u['name'],0)}\")
") || { dialog --title "$TITLE" --msgbox "\nError fetching users." 7 $W; return; }
  rm -f "$tmp_nodes" "$tmp_users"
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

preauthkeys_cleanup() {
  local ids
  ids=$(keys_json | python3 -c "
import json, sys, time
now = time.time()
for k in json.load(sys.stdin):
    exp_ts = k.get('expiration', {}).get('seconds', 0)
    if (k.get('used') and not k.get('reusable')) or (exp_ts and exp_ts < now):
        print(k['id'])
" 2>/dev/null)
  if [[ -z "$ids" ]]; then
    dialog --title "$TITLE" --msgbox "\nNo exhausted or expired keys found." 7 $W
    return
  fi
  local count; count=$(printf '%s\n' "$ids" | wc -l)
  dialog --title "$TITLE" --yesno "\nDelete $count exhausted/expired key(s)?" 7 $W || return
  local failed=0
  while IFS= read -r id; do
    headscale preauthkeys delete -i "$id" --force </dev/null 2>&1 || (( failed++ ))
  done <<< "$ids"
  dialog --title "$TITLE" --msgbox "\nDeleted $(( count - failed )) of $count key(s)." 7 $W
}

menu_preauthkeys() {
  while true; do
    dialog --title "$TITLE — Pre-Auth Keys" --menu "\nWhat would you like to do?" 16 $W 6 \
      "1" "List keys" \
      "2" "Create key" \
      "3" "Expire key" \
      "4" "Delete key" \
      "5" "Delete all exhausted/expired" \
      "0" "Back" \
      2>"$TMPFILE" || return
    case $(cat "$TMPFILE") in
      1) preauthkeys_list ;;
      2) preauthkeys_create ;;
      3) preauthkeys_expire ;;
      4) preauthkeys_delete ;;
      5) preauthkeys_cleanup ;;
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

policy_backup_current() {
  mkdir -p "$ACL_BACKUP_DIR" 2>/dev/null
  headscale policy get 2>/dev/null > "$ACL_BACKUP_DIR/policy-$(date +%Y%m%d-%H%M%S).json"
}

fmt_backup_ts() {
  local d="${1%-*}" t="${1#*-}"
  printf '%s-%s-%s %s:%s:%s' "${d:0:4}" "${d:4:2}" "${d:6:2}" "${t:0:2}" "${t:2:2}" "${t:4:2}"
}

policy_set_backup_path() {
  dialog --title "$TITLE" --inputbox "\nPath for ACL policy backups:" 9 $W "$ACL_BACKUP_DIR" 2>"$TMPFILE" || return
  local newpath; newpath=$(cat "$TMPFILE")
  [[ -z "$newpath" ]] && return
  mkdir -p "$newpath" 2>/dev/null || { dialog --title "$TITLE" --msgbox "\nCannot create/access: $newpath" 7 $W; return; }
  ACL_BACKUP_DIR="$newpath"
  grep -v '^ACL_BACKUP_DIR=' "$CONFIG_FILE" 2>/dev/null > "$CONFIG_FILE.tmp"
  printf 'ACL_BACKUP_DIR=%q\n' "$ACL_BACKUP_DIR" >> "$CONFIG_FILE.tmp"
  mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  dialog --title "$TITLE" --msgbox "\nBackup path set to:\n  $ACL_BACKUP_DIR" 8 $W
}

policy_rollback() {
  mkdir -p "$ACL_BACKUP_DIR" 2>/dev/null
  local -a files
  readarray -t files < <(ls -1t "$ACL_BACKUP_DIR"/policy-*.json 2>/dev/null)
  [[ ${#files[@]} -eq 0 ]] && { dialog --title "$TITLE" --msgbox "\nNo backups found in:\n  $ACL_BACKUP_DIR" 8 $W; return; }

  local -a items=()
  local f base
  for f in "${files[@]}"; do
    base=$(basename "$f" .json)
    items+=("$f" "$(fmt_backup_ts "${base#policy-}")")
  done
  : > "$TMPFILE"
  dialog --title "$TITLE — ACL Backups" --menu "\nSelect a version to preview:" $H $W 14 "${items[@]}" 2>"$TMPFILE" || return
  local sel; sel=$(cat "$TMPFILE")
  [[ -z "$sel" || ! -f "$sel" ]] && return

  local tmp; tmp=$(mktemp)
  cat "$sel" > "$tmp"
  dialog --title "$TITLE — Preview: $(basename "$sel")" --scrolltext --textbox "$tmp" $H $W
  rm -f "$tmp"

  dialog --title "$TITLE" --yesno "\nRestore this version as current ACL policy?\n(current policy will be backed up first)" 9 $W || return
  policy_backup_current
  local out; out=$(headscale policy set -f "$sel" </dev/null 2>&1)
  dialog --title "$TITLE" --msgbox "\n$out" 9 $W
}

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

  local jump_line=""
  while true; do
    clear
    "${EDITOR:-nano}" ${jump_line:++$jump_line} "$edit_tmp" </dev/tty >/dev/tty
    clear

    dialog --title "$TITLE" --yesno "\nSave and apply ACL policy?" 7 $W || { rm -f "$edit_tmp"; return; }

    policy_backup_current
    local out; out=$(headscale policy set -f "$edit_tmp" </dev/null 2>&1)
    if [[ $? -eq 0 ]]; then
      rm -f "$edit_tmp"
      dialog --title "$TITLE" --msgbox "\nPolicy applied successfully." 7 $W
      return
    fi

    jump_line=$(printf '%s' "$out" | grep -oE 'line [0-9]+' | head -1 | grep -oE '[0-9]+')
    local hint=""
    [[ -n "$jump_line" ]] && hint="\n\nEditor will jump to line $jump_line."
    dialog --title "$TITLE — ACL Error" \
      --extra-button --extra-label "Fix" \
      --yesno "\nError applying policy:\n\n$out$hint\n\nFix the error?" $(( H - 2 )) $W
    local rc=$?
    [[ $rc -eq 0 || $rc -eq 3 ]] || { rm -f "$edit_tmp"; return; }
  done
}

menu_policy() {
  while true; do
    dialog --title "$TITLE — ACL Policy" --menu "\nWhat would you like to do?" 14 $W 5 \
      "1" "View policy" \
      "2" "Edit policy" \
      "3" "Rollback to previous version" \
      "4" "Set backup path (current: $ACL_BACKUP_DIR)" \
      "0" "Back" \
      2>"$TMPFILE" || return
    case $(cat "$TMPFILE") in
      1) policy_view ;;
      2) policy_edit ;;
      3) policy_rollback ;;
      4) policy_set_backup_path ;;
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

# ─── Warnings ────────────────────────────────────────────────────────────────

check_warnings() {
  local tmp_nodes tmp_keys; tmp_nodes=$(mktemp); tmp_keys=$(mktemp)
  nodes_json > "$tmp_nodes"; keys_json > "$tmp_keys"
  local msg
  msg=$(python3 -c "
import json, time
now = time.time()
nodes = json.load(open('$tmp_nodes'))
keys  = json.load(open('$tmp_keys'))

issues = []
long_offline = [n['given_name'] for n in nodes
    if not n.get('online') and (now - n.get('last_seen',{}).get('seconds', now)) > 7*86400]
if long_offline:
    issues.append(f\"{len(long_offline)} node(s) offline >7 days: {', '.join(long_offline[:3])}{'...' if len(long_offline)>3 else ''}\")

expiring = [k['id'] for k in keys
    if not (k.get('used') and not k.get('reusable'))
    and k.get('expiration',{}).get('seconds',0)
    and now < k['expiration']['seconds'] < now + 3*86400]
if expiring:
    issues.append(f\"{len(expiring)} pre-auth key(s) expiring within 3 days\")

for line in issues:
    print(line)
" 2>/dev/null)
  rm -f "$tmp_nodes" "$tmp_keys"
  [[ -z "$msg" ]] && return
  dialog --title "$TITLE — Warnings" --msgbox "\n⚠  Attention:\n\n$msg" 11 $W
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
  check_warnings
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
