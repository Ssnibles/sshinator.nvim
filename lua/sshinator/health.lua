local M = {}

local health = vim.health or {
  start = function(name) vim.fn["health#report_start"](name) end,
  ok = function(msg) vim.fn["health#report_ok"](msg) end,
  warn = function(msg) vim.fn["health#report_warn"](msg) end,
  error = function(msg) vim.fn["health#report_error"](msg) end,
  info = function(msg) vim.fn["health#report_info"](msg) end,
}

function M.check()
  health.start("sshinator")

  if vim.fn.executable("ssh") == 1 then
    health.ok("ssh command found")
  else
    health.error("ssh command not found")
  end

  if vim.fn.executable("sshfs") == 1 then
    health.ok("sshfs found")
  else
    health.error("sshfs not found; install sshfs to use sshinator")
  end

  if vim.fn.executable("fusermount") == 1 or vim.fn.executable("fusermount3") == 1 then
    health.ok("fusermount/fusermount3 found")
  elseif vim.fn.executable("umount") == 1 then
    health.warn("fusermount not found; will fall back to umount")
  else
    health.error("neither fusermount nor umount found")
  end

  if vim.fn.executable("sshpass") == 1 then
    health.ok("sshpass found (password auth supported)")
  else
    health.warn("sshpass not found; password authentication not available")
  end

  local config_path = vim.fn.stdpath("config"):gsub("/[^/]+$", "") .. "/sshinator/connections.json"
  if vim.fn.filereadable(config_path) == 1 then
    health.ok("config file found: " .. config_path)
  else
    health.info("no config file yet (will be created on first :SshinatorAdd)")
  end
end

return M
