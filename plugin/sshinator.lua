local sshinator = require("sshinator")

local function cmd(fn)
  return function(opts)
    local ok, err = pcall(fn, opts)
    if not ok then
      vim.notify("sshinator: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

local function complete_connections()
  local config_path = (vim.env.XDG_CONFIG_HOME or (vim.fn.expand("~") .. "/.config"))
    .. "/sshinator/connections.json"
  local ok, data = pcall(vim.fn.readfile, config_path)
  if not ok then return {} end
  local ok, cfg = pcall(vim.fn.json_decode, table.concat(data, "\n"))
  if not ok then return {} end
  local names = {}
  for _, conn in ipairs(cfg.connections or {}) do
    table.insert(names, conn.name)
  end
  return names
end

vim.api.nvim_create_user_command("SshinatorConnect", cmd(function(opts)
  local name = opts.args ~= "" and opts.args or nil
  sshinator.connect(name)
end), { desc = "Connect to a remote SSH host", nargs = "?", complete = complete_connections })

vim.api.nvim_create_user_command("SshinatorDisconnect", cmd(function(opts)
  local name = opts.args ~= "" and opts.args or nil
  sshinator.disconnect(name)
end), { desc = "Disconnect from a mounted SSH host", nargs = "?", complete = complete_connections })

vim.api.nvim_create_user_command("SshinatorDisconnectAll", cmd(function()
  sshinator.disconnect_all()
end), { desc = "Disconnect all mounted SSH hosts" })

vim.api.nvim_create_user_command("SshinatorReconnect", cmd(function(opts)
  local name = opts.args ~= "" and opts.args or nil
  sshinator.reconnect(name)
end), { desc = "Reconnect to a mounted SSH host", nargs = "?", complete = complete_connections })

vim.api.nvim_create_user_command("SshinatorTerminal", cmd(function(opts)
  local name = opts.args ~= "" and opts.args or nil
  local force_external = nil
  if opts.bang then
    force_external = not sshinator.config.external_terminal
  end
  sshinator.open_terminal(name, force_external)
end), { desc = "Open an SSH terminal for a connection (use ! to invert external_terminal)", nargs = "?", bang = true, complete = complete_connections })

vim.api.nvim_create_user_command("SshinatorAdd", cmd(function()
  sshinator.add_connection()
end), { desc = "Add a new SSH connection" })

vim.api.nvim_create_user_command("SshinatorRemove", cmd(function(opts)
  local name = opts.args ~= "" and opts.args or nil
  sshinator.remove_connection(name)
end), { desc = "Remove a SSH connection", nargs = "?", complete = complete_connections })

vim.api.nvim_create_user_command("SshinatorEdit", cmd(function(opts)
  local name = opts.args ~= "" and opts.args or nil
  sshinator.edit_connection(name)
end), { desc = "Edit a SSH connection", nargs = "?", complete = complete_connections })

vim.api.nvim_create_user_command("SshinatorStatus", cmd(function()
  sshinator.status()
end), { desc = "Show status of all connections" })

vim.api.nvim_create_user_command("SshinatorList", cmd(function()
  sshinator.list_connections()
end), { desc = "List and manage connections" })

vim.api.nvim_create_user_command("SshinatorHealth", cmd(function()
  require("sshinator.health").check()
end), { desc = "Run sshinator health check" })
