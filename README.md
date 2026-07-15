# sshinator.nvim

A Neovim plugin for managing and mounting remote SSH connections, similar to VS Code's Remote SSH extension. Built with a Go backend for performance and reliability, and Lua for the Neovim UI.

## Features

- **Floating Window UI**: Beautiful, interactive floating windows for all prompts and selections using the Neovim floating window API
- **Password Authentication**: Support for hosts that require password authentication via a secure floating password prompt
- **Connection Management**: Add, remove, and edit SSH connections via interactive floating window prompts
- **SSHFS Mounting**: Automatically mount remote filesystems using sshfs
- **Interactive Picker**: Browse and manage connections with a custom floating window picker (keyboard navigable with j/k, number keys, etc.)
- **Status Dashboard**: View all connections and their mount status in a dedicated floating window
- **Persistent Config**: Connections stored in `~/.config/sshinator/connections.json`
- **Auto-reconnect**: sshfs configured with reconnect and keepalive options

## Requirements

- Neovim 0.8+
- Go 1.21+ (for building)
- `sshfs` (for mounting)
- `fusermount` (for unmounting)

## Installation

### Using Nix (Recommended)

Add to your Neovim configuration:

```nix
{
  inputs.sshinator.url = "github:yourusername/sshinator.nvim";
  
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
  "yourusername/sshinator.nvim",
  build = "make build",
  config = function()
    require("sshinator").setup()
  end,
}
```

With [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use {
  "yourusername/sshinator.nvim",
  run = "make build",
  config = function()
    require("sshinator").setup()
  end,
}
```

### Manual Installation

```bash
git clone https://github.com/yourusername/sshinator.nvim
cd sshinator.nvim
make build
```

Then add the plugin directory to your Neovim runtime path.

## Usage

### Commands

- `:SshinatorAdd` - Add a new SSH connection (interactive floating window prompts)
- `:SshinatorConnect` - Connect to a remote host (floating window picker)
- `:SshinatorDisconnect` - Disconnect from a mounted host
- `:SshinatorDisconnectAll` - Disconnect all mounted hosts
- `:SshinatorRemove` - Remove a connection
- `:SshinatorStatus` - Show status of all connections in a floating window dashboard
- `:SshinatorList` - List and manage connections (with action picker)

### Floating Window UI

All interactions use custom floating windows:

- **Input prompts**: Centered floating windows for text entry (name, host, user, etc.)
- **Password prompts**: Secure password entry with masked input (displays `*` characters)
- **Selection pickers**: Keyboard-navigable lists with visual highlighting
  - `j`/`k` or `↑`/`↓` to navigate
  - `<CR>` to select
  - `1`-`9` for quick selection
  - `gg`/`G` to jump to first/last
  - `q` or `<Esc>` to cancel
- **Status dashboard**: Color-coded connection status (green for mounted, red for unmounted)
- **Notifications**: Floating window notifications that auto-dismiss after 5 seconds

### Password Authentication

For hosts that require password authentication:

1. When adding a connection with `:SshinatorAdd`, answer "y" to the "Use password auth?" prompt
2. When connecting with `:SshinatorConnect`, you'll be prompted for your password via a secure floating window
3. The password is never stored - it's only used for the current mount session

### Example Workflow

1. Add a connection:
   ```
   :SshinatorAdd
   ```
   Follow the floating window prompts to enter name, host, user, port, remote path, optional identity file, and whether to use password authentication.

2. Connect to a host:
   ```
   :SshinatorConnect
   ```
   Select from your configured connections using the floating window picker. If the connection requires a password, you'll be prompted securely. The remote filesystem will be mounted and opened in Neovim.

3. View mounted connections:
   ```
   :SshinatorStatus
   ```
   A floating window dashboard shows all connections with their current mount status.

4. Disconnect:
   ```
   :SshinatorDisconnect
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
│   ├── ui.lua              # Floating window UI components
│   └── picker.lua          # Picker wrapper
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
- **Password Auth**: Uses SSH_ASKPASS mechanism to securely pass passwords to sshfs without storing them

## Mount Locations

Remote filesystems are mounted to `~/.local/share/sshinator/mounts/<connection-name>/`

## License

MIT
