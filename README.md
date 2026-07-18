# sshinator.nvim

A Neovim plugin for managing and mounting remote SSH connections, similar to VS Code's Remote SSH extension. Built with a Go backend for performance and reliability, and Lua for the Neovim UI.

## Features

- **Floating Window UI**: Beautiful, interactive floating windows for all prompts and selections using the Neovim floating window API
- **Password Authentication**: Support for hosts that require password authentication via a secure floating password prompt with masked input
- **Connection Testing**: Optionally test connections when adding them to verify they work
- **Connection Management**: Add, remove, and edit SSH connections via interactive floating window prompts
- **Command Arguments**: Pass connection names directly to commands (e.g., `:SshinatorConnect hostname`) with tab completion
- **SSHFS Mounting**: Automatically mount remote filesystems using sshfs with timeout protection
- **Interactive Fuzzy Picker**: Browse and manage connections with a custom floating window picker; type `/` to filter the list
- **SSH Config Port Detection**: Automatically uses the port from your `~/.ssh/config` when adding, editing, and connecting to hosts
- **Yes/No Confirm Picker**: Clean boolean prompts with a dedicated Yes/No interface
- **Status Dashboard**: View all connections and their mount status in a dedicated floating window
- **Persistent Config**: Connections stored in `~/.config/sshinator/connections.json`
- **Auto-reconnect**: sshfs configured with reconnect and keepalive options
- **Stale Mount Cleanup**: Automatically cleans up stale mount points before connecting

## Requirements

- Neovim 0.8+
- Go 1.21+ (for building)
- `sshfs` (for mounting)
- `fusermount` or `fusermount3` (for unmounting)
- `sshpass` (optional, for password authentication)

## Installation

### Using Nix (Recommended)

Add to your Neovim configuration:

```nix
{
  inputs.sshinator.url = "github:Ssnibles/sshinator.nvim";

  # In your neovim plugins list:
  extraPlugins = [ inputs.sshinator.packages.${system}.default ];
}
```

Or install directly:

```bash
nix build .#default
```

### Using a Plugin Manager

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "Ssnibles/sshinator.nvim",
  build = "make build",
  config = function()
    require("sshinator").setup()
  end,
}
```

With [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use {
  "Ssnibles/sshinator.nvim",
  run = "make build",
  config = function()
    require("sshinator").setup()
  end,
}
```

### Manual Installation

```bash
git clone https://github.com/Ssnibles/sshinator.nvim
cd sshinator.nvim
make build
```

Then add the plugin directory to your Neovim runtime path.

## Usage

### Commands

All commands support tab completion for connection names where applicable.

- `:SshinatorAdd` - Add a new SSH connection (interactive floating window prompts)
- `:SshinatorConnect [name]` - Connect to a remote host (floating window picker if no name provided)
- `:SshinatorDisconnect [name]` - Disconnect from a mounted host (picker if no name provided)
- `:SshinatorDisconnectAll` - Disconnect all mounted hosts
- `:SshinatorReconnect [name]` - Reconnect to a mounted host (picker if no name provided)
- `:SshinatorRemove [name]` - Remove a connection (picker if no name provided)
- `:SshinatorEdit [name]` - Edit a connection (picker if no name provided)
- `:SshinatorStatus` - Show status of all connections in a floating window dashboard
- `:SshinatorList` - List and manage connections (with action picker including Connect, Disconnect, Reconnect, Edit, Status, Remove)
- `:SshinatorHealth` - Run sshinator health check (also available via `:checkhealth sshinator`)

### Floating Window UI

All interactions use custom floating windows:

- **Input prompts**: Centred floating windows for text entry (name, host, user, etc.)
- **Password prompts**: Secure password entry with masked input (displays `*` characters)
- **Yes/No confirm**: Clean boolean prompts with Yes/No options (j/k to toggle, y/n for quick select)
- **Selection pickers**: Keyboard-navigable lists with visual highlighting and fuzzy filtering
  - `j`/`k` or `↑`/`↓` to navigate
  - `/` to start filtering the list
  - `<CR>` to select
  - `1`-`9` for quick selection
  - `gg`/`G` to jump to first/last
  - `q` or `<Esc>` to cancel
- **Status dashboard**: Colour-coded connection status (green for mounted, red for unmounted)
- **Notifications**: Floating window notifications that auto-dismiss after 5 seconds

### Password Authentication

For hosts that require password authentication:

1. When adding a connection with `:SshinatorAdd`, select "Yes" on the "Use password auth?" prompt
2. When connecting with `:SshinatorConnect`, you'll be prompted for your password via a secure floating window
3. The password is never stored - it's only used for the current mount session
4. If `sshpass` is available, it will be used for more reliable password authentication; otherwise, the plugin falls back to `password_stdin`

### Example Workflow

1. Add a connection:

   ```
   :SshinatorAdd
   ```

   Follow the floating window prompts to enter name, host, user, port, remote path, optional identity file, and whether to use password authentication. The **Port** field defaults to the value from your `~/.ssh/config` (falling back to `22`). You'll be prompted to test the connection after adding it.

2. Connect to a host:

   ```
   :SshinatorConnect
   ```

   Select from your configured connections using the floating window picker, or pass the connection name directly:

   ```
   :SshinatorConnect my-server
   ```

   If the connection requires a password, you'll be prompted securely. The remote filesystem will be mounted and opened in Neovim.

3. View mounted connections:

   ```
   :SshinatorStatus
   ```

   A floating window dashboard shows all connections with their current mount status.

4. Disconnect:

   ```
   :SshinatorDisconnect
   ```

   Or disconnect a specific connection:

   ```
   :SshinatorDisconnect my-server
   ```

5. Edit a connection:

   ```
   :SshinatorEdit my-server
   ```

### Configuration

Connections are stored in `~/.config/sshinator/connections.json`:

```json
{
  "connections": [
    {
      "name": "my-server",
      "host": "example.com",
      "port": 22,
      "user": "josh",
      "identity_file": "~/.ssh/id_rsa",
      "remote_path": "/home/josh/projects",
      "password_auth": false
    },
    {
      "name": "password-server",
      "host": "secure.example.com",
      "port": 22,
      "user": "admin",
      "remote_path": "/var/www",
      "password_auth": true
    }
  ]
}
```

You can edit this file directly or use the plugin commands.

## Development

### Building from Source

```bash
nix develop  # or: nix-shell
make build
```

### Project Structure

```
sshinator.nvim/
├── cmd/sshinator/          # Go main entry point
├── internal/
│   ├── config/             # Connection config management
│   ├── mount/              # SSHFS mounting logic
│   └── rpc/                # JSON-RPC server
├── lua/sshinator/          # Lua frontend
│   ├── init.lua            # Main module
│   ├── rpc.lua             # RPC client
│   └── ui.lua              # Floating window UI components
├── plugin/                 # Neovim plugin entry
│   └── sshinator.lua       # Command definitions
├── flake.nix               # Nix flake
├── default.nix             # Nix package
└── shell.nix               # Dev shell
```

### Architecture

- **Go Backend**: JSON-RPC server over stdio, handles SSH config management and sshfs mounting
- **Lua Frontend**: Spawns Go binary, provides floating window UI, registers Neovim commands
- **Communication**: JSON-RPC over stdio (newline-delimited JSON)
- **Password Auth**: Uses `sshpass` when available for reliable password authentication, falls back to `password_stdin` otherwise
- **Timeout Protection**: All sshfs operations have a 30-second timeout to prevent hangs
- **Stale Mount Detection**: Automatically detects and cleans up stale mount points before connecting

## Mount Locations

Remote filesystems are mounted to `~/.local/share/sshinator/mounts/<connection-name>/`

## Limitations

- SSHFS mounts with the permissions of your SSH user, so you cannot write to root-owned directories (e.g., `/etc/nixos`) without additional setup
- For editing protected system files, consider symlinking configuration directories to your home directory or using alternative methods

## License

MIT
