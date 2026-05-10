# headscale-bash-manager

A full-featured terminal UI for managing a [Headscale](https://github.com/juanfont/headscale) server (self-hosted Tailscale control plane). Runs directly on the Headscale server. Built with `dialog` for the interface and `python3` for JSON parsing — no `jq` required.

## Requirements

- Headscale v0.28+
- `dialog` (`apt install dialog`)
- `python3`

## Installation

```bash
# Copy to the server
scp headscale-manager.sh root@your-server:/usr/local/bin/headscale-manager
chmod +x /usr/local/bin/headscale-manager

# Run
headscale-manager
```

## Features

### Nodes
- List all nodes — ID, online status (●/○), name, user, Tailscale IP, last seen, route counts
- Rename a node
- Expire a node (forces re-authentication)
- Delete a node
- Manage routes — checklist combining both available and approved routes
- Set tags — comma-separated input, automatically prefixes `tag:`
- Register a new node — enter node key, select user

### Users
- List all users
- Create user
- Rename user
- Delete user

### Pre-Auth Keys
- List all keys — user, expiry, used, reusable, ephemeral flags
- Create key — select user, set expiry, optionally reusable and/or ephemeral
- Expire key
- Delete key

### API Keys
- List all keys — prefix and expiry
- Create key — set expiry, key is shown once
- Expire key
- Delete key

### ACL Policy
- View current policy (scrollable)
- Edit policy in-place — opens HuJSON in an editbox, applies on save

### Health
- Displays `headscale health` output with per-check status

## UI

- Mouse support
- Adapts to terminal size automatically (SIGWINCH)
- ESC or the **0 — Back** entry in every submenu returns to the previous screen
