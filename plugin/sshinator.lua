local sshinator = require("sshinator")

local function cmd(fn)
  return function()
    local ok, err = pcall(fn)
    if not ok then
      vim.notify("sshinator: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

vim.api.nvim_create_user_command("SshinatorConnect", cmd(function()
  sshinator.connect()
end), { desc = "Connect to a remote SSH host" })

vim.api.nvim_create_user_command("SshinatorDisconnect", cmd(function()
  sshinator.disconnect()
end), { desc = "Disconnect from a mounted SSH host" })

vim.api.nvim_create_user_command("SshinatorDisconnectAll", cmd(function()
  sshinator.disconnect_all()
end), { desc = "Disconnect all mounted SSH hosts" })

vim.api.nvim_create_user_command("SshinatorReconnect", cmd(function()
  sshinator.reconnect()
end), { desc = "Reconnect to a mounted SSH host" })

vim.api.nvim_create_user_command("SshinatorAdd", cmd(function()
  sshinator.add_connection()
end), { desc = "Add a new SSH connection" })

vim.api.nvim_create_user_command("SshinatorRemove", cmd(function()
  sshinator.remove_connection()
end), { desc = "Remove a SSH connection" })

vim.api.nvim_create_user_command("SshinatorStatus", cmd(function()
  sshinator.status()
end), { desc = "Show status of all connections" })

vim.api.nvim_create_user_command("SshinatorList", cmd(function()
  sshinator.list_connections()
end), { desc = "List and manage connections" })

vim.api.nvim_create_user_command("SshinatorHealth", cmd(function()
  require("sshinator.health").check()
end), { desc = "Run sshinator health check" })
