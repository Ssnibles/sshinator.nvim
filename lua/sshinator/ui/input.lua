local M = {}
local float = require("sshinator.ui.float")

function M.open(opts, callback)
  opts = opts or {}
  local title = opts.title or opts.prompt or "Input"
  local default = tostring(opts.default or "")
  local mask = opts.mask or false
  local width = math.max(50, vim.fn.strdisplaywidth(title) + 20)

  local buf, win = float.create_float({
    title = title,
    width = width,
    height = 1,
  })
  if not buf or not win then
    callback(nil)
    return
  end

  vim.bo[buf].buftype = "nofile"
  vim.b[buf].completion = false

  local submitted = false

  local function submit()
    if submitted then return end
    submitted = true
    local value = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
    float.close_float(win)
    vim.cmd("stopinsert")
    callback(value ~= "" and value or nil)
  end

  local function cancel()
    if submitted then return end
    submitted = true
    float.close_float(win)
    vim.cmd("stopinsert")
    callback(nil)
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { default })

  if mask then
    float.set_win_option(win, "conceallevel", 2)
    float.set_win_option(win, "concealcursor", "nvic")
    vim.fn.matchadd("Conceal", ".", 10, -1, { conceal = "*" })
  end

  vim.cmd("startinsert!")

  vim.keymap.set("i", "<CR>", submit, { buffer = buf, noremap = true })
  vim.keymap.set("n", "<CR>", submit, { buffer = buf, noremap = true })
  vim.keymap.set("i", "<Esc>", cancel, { buffer = buf, noremap = true })
  vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, noremap = true })
  vim.keymap.set("n", "q", cancel, { buffer = buf, noremap = true })

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    nested = true,
    once = true,
    callback = cancel,
  })
end

return M
