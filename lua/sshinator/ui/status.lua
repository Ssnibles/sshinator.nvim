local M = {}
local float = require("sshinator.ui.float")

function M.open(connections, mounted)
  local lines = {}
  local highlights = {}

  table.insert(lines, "")
  table.insert(highlights, { group = float.hl_groups.muted, line = #lines - 1 })

  for _, conn in ipairs(connections) do
    local is_conn_mounted = mounted[conn.name] ~= nil
    local icon = is_conn_mounted and "[connected]" or "[disconnected]"
    local line = string.format("  %s  %-20s %s@%s:%d", icon, conn.name, conn.user, conn.host, conn.port or 22)
    if is_conn_mounted then
      line = line .. "  ->  " .. mounted[conn.name]
    end
    table.insert(lines, line)
    table.insert(highlights, {
      group = is_conn_mounted and float.hl_groups.status_mounted or float.hl_groups.status_unmounted,
      line = #lines - 1,
    })
    table.insert(lines, "")
    table.insert(highlights, { group = float.hl_groups.muted, line = #lines - 1 })
  end

  local max_width = 60
  for _, line in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(line)
    if w > max_width then
      max_width = w
    end
  end
  local columns, lines_count = float.get_ui_size()
  local width = math.min(math.max(max_width + 4, 50), math.floor(columns * 0.85))
  local height = math.min(#lines, math.floor(lines_count * 0.7))

  local buf, win = float.create_float({
    title = "Connection Status",
    width = width,
    height = height,
  })
  if not buf or not win then
    return
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local ns = float.get_ns_id()
  for _, h in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(buf, ns, h.group, h.line, 0, -1)
  end

  local closed = false
  local function close()
    if closed then return end
    closed = true
    float.close_float(win)
  end

  vim.keymap.set("n", "<CR>", close, { buffer = buf, noremap = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, noremap = true })
  vim.keymap.set("n", "q", close, { buffer = buf, noremap = true })

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = close,
  })
end

return M
