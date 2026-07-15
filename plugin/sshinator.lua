local sshinator = require("sshinator")

vim.api.nvim_create_user_command("SshinatorConnect", function()
  sshinator.connect()
end, { desc = "Connect to a remote SSH host" })

vim.api.nvim_create_user_command("SshinatorDisconnect", function()
  sshinator.disconnect()
end, { desc = "Disconnect from a mounted SSH host" })

vim.api.nvim_create_user_command("SshinatorDisconnectAll", function()
  sshinator.disconnect_all()
end, { desc = "Disconnect all mounted SSH hosts" })

vim.api.nvim_create_user_command("SshinatorAdd", function()
  sshinator.add_connection()
end, { desc = "Add a new SSH connection" })

vim.api.nvim_create_user_command("SshinatorRemove", function()
  sshinator.remove_connection()
end, { desc = "Remove an SSH connection" })

vim.api.nvim_create_user_command("SshinatorStatus", function()
  sshinator.status()
end, { desc = "Show status of all connections" })

vim.api.nvim_create_user_command("SshinatorList", function()
  sshinator.list_connections()
end, { desc = "List and manage connections" })
