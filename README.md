# headscale-bash-manager

A full-featured terminal UI for managing a [Headscale](https://github.com/juanfont/headscale) server (self-hosted Tailscale control plane). Runs directly on the Headscale server.
## Requirements

- Headscale v0.29+
- `dialog` (`apt install dialog`)
- `python3`
- A terminal editor for ACL editing (`nano` by default, override with `$EDITOR`)
- ACL policy features assume `policy.mode: file` in `config.yaml` (the standard headscale setup); `database` mode is not supported by the ACL editor

## Features

### Nodes
- List all nodes: ID, online status (●/○), name, user, Tailscale IP, last seen, route counts
- Online nodes only
- Node details: status, user, IPs, last seen, expiry, tags, routes
- Routes overview across all nodes
- Rename a node
- Expire a node (forces re-authentication, keeps the node in the database)
- Delete a node
- Manage routes: checklist combining both available and approved routes
- Set tags: comma-separated input, automatically prefixes `tag:` (requires matching `tagOwners` entries in the ACL policy, otherwise headscale rejects the tag)
- Register a new node: paste the register URL or auth-id shown by `tailscale login`, select user
- Copy node IP

### Users
- List all users
- Create user
- Rename user
- Delete user

### Pre-Auth Keys
- List all keys: user, expiry, used, reusable, ephemeral flags
- Create key: select user, set expiry, optionally reusable and/or ephemeral
- Expire key
- Delete key
- Delete all exhausted/expired keys in one step

### API Keys
- List all keys: prefix and expiry
- Create key: set expiry, key is shown once
- Expire key
- Delete key

### ACL Policy
- View current policy (scrollable)
- Edit policy in a real editor (`nano`/`$EDITOR`), so normal terminal copy and paste works
- Validates with `headscale policy check` before writing anything; on error the editor reopens and jumps straight to the offending line
- Applies by writing directly to the file `headscale` watches, so it reloads automatically, no restart needed
- Rollback to a previous version: browse a timestamped history, preview before restoring
- Only policies that pass `headscale policy check` ever enter that history, broken states are never offered for rollback
- Backup path is configurable and persists across runs

### Health
- Displays `headscale health` output with per-check status
- Startup warnings: long-offline nodes, keys about to expire, and similar issues are flagged automatically

## UI

- Mouse support
- Adapts to terminal size automatically (SIGWINCH)
<img width="1797" height="520" alt="image" src="https://github.com/user-attachments/assets/04d2aea2-d5d8-4eca-b7d4-81fca7411cd8" />
