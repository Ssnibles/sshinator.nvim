local M = {}

function M.check()
  vim.health.start("sshinator")

  local init = require("sshinator")
  local binary = init.get_binary_path()
  if binary and vim.fn.executable(binary) == 1 then
    vim.health.ok("binary found: " .. binary)
  else
    vim.health.error("sshinator binary not found. Run 'make build' first.")
    return
  end

  local has_sshfs = vim.fn.executable("sshfs") == 1
  local has_fusermount = vim.fn.executable("fusermount") == 1

  if has_sshfs then
    vim.health.ok("sshfs found")
  else
    vim.health.error("sshfs not found. Install sshfs to use sshinator.")
  end

  if has_fusermount then
    vim.health.ok("fusermount found")
  else
    local has_umount = vim.fn.executable("umount") == 1
    if has_umount then
      vim.health.warn("fusermount not found, will fall back to umount")
    else
      vim.health.error("neither fusermount nor umount found")
    end
  end

  local config_dir = vim.fn.stdpath("config")
  local config_path = config_dir .. "/../sshinator/connections.json"
  local home = vim.env.HOME or ""
  local xdg_config = vim.env.XDG_CONFIG_HOME or (home .. "/.config")
  config_path = xdg_config .. "/sshinator/connections.json"

  if vim.fn.filereadable(config_path) == 1 then
    vim.health.ok("config file found: " .. config_path)
  else
    vim.health.info("no config file yet (will be created on first :SshinatorAdd)")
  end

  local ok, client = pcall(function()
    return init._get_client()
  end)
  if ok and client and client:is_running() then
    vim.health.ok("RPC process running")
  elseif ok then
    vim.health.info("RPC process not started (will start on first command)")
  else
    vim.health.warn("could not check RPC status")
  end
end

return M
