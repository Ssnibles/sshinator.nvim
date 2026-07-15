# sshinator.nvim

A Neovim plugin for managing and mounting remote SSH connections, similar to VS Code's Remote SSH extension. Built with a Go backend for performance and reliability, and Lua for the Neovim UI.

## Features

- **Connection Management**: Add, remove, and edit SSH connections via interactive prompts
- **SSHFS Mounting**: Automatically mount remote filesystems using sshfs
- **Picker UI**: Browse and manage connections with vim.ui.select (integrates with telescope, fzf-lua, etc.)
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

- `:SshinatorAdd` - Add a new SSH connection (interactive prompts)
- `:SshinatorConnect` - Connect to a remote host (picker UI)
- `:SshinatorDisconnect` - Disconnect from a mounted host
- `:SshinatorDisconnectAll` - Disconnect all mounted hosts
- `:SshinatorRemove` - Remove a connection
- `:SshinatorStatus` - Show status of all connections
- `:SshinatorList` - List and manage connections (with action picker)

### Example Workflow

1. Add a connection:
   ```
   :SshinatorAdd
   ```
   Follow the prompts to enter name, host, user, port, remote path, and optional identity file.

2. Connect to a host:
   ```
   :SshinatorConnect
   ```
   Select from your configured connections. The remote filesystem will be mounted and opened in Neovim.

3. View mounted connections:
   ```
   :SshinatorStatus
   ```

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
      "remote_path": "/home/josh/projects"
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
│   └── picker.lua          # UI picker wrapper
├── plugin/                 # Neovim plugin entry
│   └── sshinator.lua       # Command definitions
├── flake.nix               # Nix flake
├── default.nix             # Nix package
└── shell.nix               # Dev shell
```

### Architecture

- **Go Backend**: JSON-RPC server over stdio, handles SSH config management and sshfs mounting
- **Lua Frontend**: Spawns Go binary, provides picker UI via `vim.ui.select`, registers Neovim commands
- **Communication**: JSON-RPC over stdio (newline-delimited JSON)

## Mount Locations

Remote filesystems are mounted to `~/.local/share/sshinator/mounts/<connection-name>/`

## License

MIT
