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

  if vim.fn.executable("rclone") == 1 then
    health.ok("rclone found (SFTP mount backend)")
  else
    health.error("rclone not found; install rclone to use sshinator")
  end

  if vim.fn.executable("mountpoint") == 1 then
    health.ok("mountpoint found")
  else
    health.warn("mountpoint not found; mount status detection will not work")
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

  local config_path = require("sshinator").config_path()
  if vim.fn.filereadable(config_path) == 1 then
    health.ok("config file found: " .. config_path)
  else
    health.info("no config file yet (will be created on first :SshinatorAdd)")
  end
end

return M
