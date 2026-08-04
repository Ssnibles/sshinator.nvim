# sshinator.nvim

A Neovim plugin for managing and mounting remote SSH connections, similar to VS Code's Remote SSH extension. Uses rclone for fast, async remote filesystem mounting and Lua for the Neovim UI.

## Features

- **Floating Window UI**: Beautiful, interactive floating windows for all prompts and selections using the Neovim floating window API
- **Password Authentication**: Support for hosts that require password authentication via a secure floating password prompt with masked input
- **Connection Testing**: Optionally test connections when adding them to verify they work
- **Connection Management**: Add, remove, and edit SSH connections via interactive floating window prompts
- **Command Arguments**: Pass connection names directly to commands (e.g., `:SshinatorConnect hostname`) with tab completion
- **rclone SFTP Mounting**: Fast, async remote filesystem mounting using rclone's SFTP backend with VFS write caching, parallel transfers, and directory caching
- **Interactive Fuzzy Picker**: Browse and manage connections with a custom floating window picker; type `/` to filter the list
- **SSH Config Port Detection**: Automatically detects the port from your `~/.ssh/config` when adding connections (async, non-blocking)
- **Yes/No Confirm Picker**: Clean boolean prompts with a dedicated Yes/No interface
- **Status Dashboard**: View all connections and their mount status in a dedicated floating window
- **Persistent Config**: Connections stored in `~/.config/sshinator/connections.json`
- **Async Operations**: All mount/unmount/status operations are fully async using Neovim's job control

## Requirements

- Neovim 0.8+
- `rclone` (for SFTP mounting - faster and more reliable than sshfs)
- `ssh` (for terminal sessions and port detection)
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
  config = function()
    require("sshinator").setup()
  end,
}
```

With [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use {
  "Ssnibles/sshinator.nvim",
  config = function()
    require("sshinator").setup()
  end,
}
```

### Manual Installation

```bash
git clone https://github.com/Ssnibles/sshinator.nvim
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
 4. rclone obscures passwords via `rclone obscure` before passing them to the SFTP backend

### Example Workflow

1. Add a connection:

   ```
   :SshinatorAdd
   ```

   Follow the floating window prompts to enter name, host, user, port, remote path, optional identity file, and whether to use password authentication. The **Port** field defaults to the detected value from your `~/.ssh/config` (falling back to `22`), detected asynchronously. You'll be prompted to test the connection after adding it.

2. Connect to a host:

   ```
   :SshinatorConnect
   ```

   Select from your configured connections using the floating window picker, or pass the connection name directly:

   ```
   :SshinatorConnect my-server
   ```

   If the connection requires a password, you'll be prompted securely. The remote filesystem will be mounted via rclone and opened in Neovim.

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

### Plugin Options

All options are set via `require("sshinator").setup({...})`:

```lua
require("sshinator").setup({
  -- Core behavior
  auto_check_deps = true,           -- warn on missing dependencies at startup
  notify_duration = 5000,           -- ms before notifications auto-dismiss
  request_timeout = 60000,          -- ms timeout for mount operations

  -- User experience
  external_terminal = false,        -- open SSH terminal in external emulator
  auto_terminal = true,             -- open an SSH terminal automatically on connect
  auto_chdir = true,                -- cd to mount point + open dir on connect

  -- rclone performance tuning
  vfs_cache_mode = "writes",        -- off | minimal | writes | full
  dir_cache_time = "5m",            -- duration to cache directory listings
  transfers = 4,                    -- parallel file transfers
  checkers = 8,                     -- parallel file checkers

  -- Paths (nil = use XDG defaults)
  cache_dir = nil,                  -- rclone VFS cache dir (default: $XDG_CACHE_HOME/sshinator/rclone)
  mount_base = nil,                 -- base dir for mounts (default: $XDG_DATA_HOME/sshinator/mounts)
})
```

## rclone Performance

The plugin mounts remote filesystems with these rclone optimizations:

- `--vfs-cache-mode writes` - Write-back caching for fast edits
- `--dir-cache-time 5m` - Directory listings cached for 5 minutes
- `--transfers 4` / `--checkers 8` - Parallel file transfers and checks
- `--no-checksum` - Skip checksum verification for speed
- `--daemon` - Background mount process
- `--sftp-shell-type=unix` / `--sftp-set-modtime=false` - Skip shell auto-detection for faster startup
- `--sftp-md5sum-command=none` / `--sftp-sha1sum-command=none` - Skip hash command auto-detection

Cache files are stored at `$XDG_CACHE_HOME/sshinator/rclone/` (defaults to `~/.cache/sshinator/rclone/`).

## Troubleshooting

If a mount fails, check the rclone daemon log:

```bash
cat /tmp/sshinator-rclone-<connection-name>.log
```

The error notification will also include stderr output from the mount command.

## Project Structure

```
sshinator.nvim/
├── lua/sshinator/
│   ├── init.lua              # Core rclone mounting and connection logic
│   ├── ui.lua                # Floating window UI components
│   └── health.lua            # Health check diagnostics
├── plugin/
│   └── sshinator.lua         # Neovim command definitions
├── default.nix               # Nix package
└── README.md
```

## Architecture

- **rclone Backend**: rclone SFTP mount provides fast, reliable remote filesystem access with built-in VFS caching and parallel transfers
- **Async Operations**: All mount, unmount, and status checks use `vim.fn.jobstart` for non-blocking operation
- **Lua Frontend**: Pure Lua UI with floating windows, no external binary dependencies beyond rclone/ssh

## Mount Locations

Remote filesystems are mounted to `~/.local/share/sshinator/mounts/<connection-name>/`

## Limitations

- rclone mounts with the permissions of your SSH user, so you cannot write to root-owned directories without additional setup
- For editing protected system files, consider symlinking configuration directories to your home directory or using alternative methods

## License

MIT
