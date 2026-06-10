-- git-approve.nvim — review staged-but-unapproved files, approve them, and
-- stage buffer text without touching the working tree.
--
-- Self-contained: shells out to `git` and the `git-approve` CLI. No fugitive
-- dependency (an optional FugitiveReal() fallback is used for path resolution
-- if it happens to be available).

local M = {}

local uv = vim.uv or vim.loop

-- Per-git-dir index mtime, so external `git add`s can be detected cheaply.
local index_mtime = {}

local function err(msg)
  vim.api.nvim_echo({ { 'git-approve: ' .. msg, 'ErrorMsg' } }, true, {})
end

local function info(msg)
  vim.api.nvim_echo({ { msg } }, false, {})
end

local function trim(s)
  return (s:gsub('%s+$', ''))
end

-- Repo root for the current working directory, or nil on failure.
local function repo_root()
  local out = vim.fn.systemlist({ 'git', 'rev-parse', '--show-toplevel' })
  if vim.v.shell_error ~= 0 or #out == 0 then
    err('not in a git repository')
    return nil
  end
  return out[1]
end

-- Absolute git dir for `root` (per-worktree), or nil.
local function git_dir(root)
  local out = vim.fn.systemlist({ 'git', '-C', root, 'rev-parse', '--absolute-git-dir' })
  if vim.v.shell_error ~= 0 or #out == 0 then
    return nil
  end
  return out[1]
end

-- Staged-but-unapproved paths (repo-root-relative), or {} on error.
local function pending()
  local lines = vim.fn.systemlist({ 'git-approve', 'pending' })
  if vim.v.shell_error ~= 0 then
    err(table.concat(lines, ' '))
    return {}
  end
  return vim.tbl_filter(function(l) return l ~= '' end, lines)
end

-- Lines of `<rev>:<path>` (rev '' means index stage 0), or nil if absent.
local function blob(root, rev, path)
  local lines = vim.fn.systemlist({ 'git', '-C', root, 'show', rev .. ':' .. path })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return lines
end

local function head_has(root, path)
  vim.fn.system({ 'git', '-C', root, 'cat-file', '-e', 'HEAD:' .. path })
  return vim.v.shell_error == 0
end

-- Create a scratch buffer holding `lines`, named `name`, syntax-highlighted by
-- `path`'s extension. `modifiable` controls whether the user can edit it.
local function scratch(lines, name, path, modifiable)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  pcall(vim.api.nvim_buf_set_name, buf, name)
  local ft = vim.filetype.match({ filename = path })
  if ft then
    vim.bo[buf].filetype = ft
  end
  vim.bo[buf].modifiable = modifiable
  vim.bo[buf].modified = false
  return buf
end

-- Open one tab diffing HEAD (or empty, for added files) against the staged
-- blob. Returns the new tabpage handle, or nil on failure.
local function open_diff(root, path)
  local staged = blob(root, '', path)
  if not staged then
    err('cannot read staged version of ' .. path)
    return
  end
  local head = head_has(root, path) and (blob(root, 'HEAD', path) or {}) or {}

  vim.cmd('tabnew')

  -- Left: HEAD / empty (read-only).
  local lbuf = scratch(head, path .. ' ◍HEAD', path, false)
  vim.api.nvim_win_set_buf(0, lbuf)
  vim.b[lbuf].git_approve_path = path
  vim.cmd('diffthis')

  -- Right: staged (editable, so it can be tweaked and re-staged).
  vim.cmd('vsplit')
  local rbuf = scratch(staged, path .. ' ◍staged', path, true)
  vim.api.nvim_win_set_buf(0, rbuf)
  vim.b[rbuf].git_approve_path = path
  vim.b[rbuf].git_approve_staged = true
  vim.cmd('diffthis')
  return vim.api.nvim_get_current_tabpage()
end

function M.review()
  local files = pending()
  if #files == 0 then
    info('git-approve: nothing staged and unapproved')
    return
  end
  local root = repo_root()
  if not root then
    return
  end
  local first
  for _, path in ipairs(files) do
    local tp = open_diff(root, path)
    first = first or tp
  end
  if first then
    vim.api.nvim_set_current_tabpage(first)
  end
end

-- Reload the staged side of any diff in the current tab (content-only).
local function refresh_staged()
  local root = repo_root()
  if not root then
    return
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.b[buf].git_approve_staged and not vim.bo[buf].modified then
      local lines = blob(root, '', vim.b[buf].git_approve_path)
      if lines then
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modified = false
      end
    end
  end
  vim.cmd('diffupdate')
end

-- Cheap autocmd hook: only does work when the visible tab has a review diff and
-- the index actually changed since last seen.
function M.maybe_refresh()
  local has = false
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.b[vim.api.nvim_win_get_buf(win)].git_approve_staged then
      has = true
      break
    end
  end
  if not has then
    return
  end
  local root = repo_root()
  if not root then
    return
  end
  local gd = git_dir(root)
  if not gd then
    return
  end
  local st = uv.fs_stat(gd .. '/index')
  local mtime = st and (st.mtime.sec * 1000000000 + st.mtime.nsec) or 0
  if index_mtime[gd] == mtime then
    return
  end
  index_mtime[gd] = mtime
  refresh_staged()
end

-- The file the approve/stage commands act on, as an absolute path.
local function current_file()
  local p = vim.b.git_approve_path
  if p and p ~= '' then
    local root = repo_root()
    if root then
      return root .. '/' .. p
    end
  end
  if vim.fn.exists('*FugitiveReal') == 1 then
    local real = vim.fn.FugitiveReal('%')
    if real ~= '' then
      return real
    end
  end
  return vim.fn.expand('%:p')
end

-- git-approve approve|revoke on `args` (or the current file when empty).
function M.run(subcmd, args)
  local target = args
  if not target or target == '' then
    local file = current_file()
    if file == '' then
      err('no file')
      return
    end
    target = vim.fn.shellescape(file)
  end
  local out = vim.fn.system('git-approve ' .. subcmd .. ' ' .. target)
  info(trim(out))
end

-- Stage the current buffer's text into the index and approve that path. The
-- working-tree file is NOT modified: we hash the buffer to a blob and point the
-- index entry at it. Works on a normal file buffer and on a review staged buffer.
function M.stage_approve()
  local root, rel

  if vim.b.git_approve_path and vim.b.git_approve_path ~= '' then
    root = repo_root()
    rel = vim.b.git_approve_path
  else
    local file = current_file()
    if file == '' then
      err('no file')
      return
    end
    local dir = vim.fn.fnamemodify(file, ':h')
    local i = vim.fn.systemlist({ 'git', '-C', dir, 'rev-parse', '--show-toplevel', '--show-prefix' })
    if vim.v.shell_error ~= 0 or #i == 0 then
      err('not in a git repository')
      return
    end
    root = i[1]
    rel = (i[2] or '') .. vim.fn.fnamemodify(file, ':t')
  end
  if not root then
    return
  end

  -- Serialize the buffer to a temp file (Vim's exact write logic), then hash it
  -- — the working tree is untouched.
  local tmp = vim.fn.tempname()
  vim.cmd('silent keepalt write! ' .. vim.fn.fnameescape(tmp))
  local oid = trim(vim.fn.system({ 'git', '-C', root, 'hash-object', '-w', '--', tmp }))
  vim.fn.delete(tmp)
  if vim.v.shell_error ~= 0 or oid == '' then
    err('git hash-object failed')
    return
  end

  -- Preserve the existing index mode if tracked, else default.
  local mode = '100644'
  local ls = vim.fn.systemlist({ 'git', '-C', root, 'ls-files', '-s', '--', rel })
  if #ls > 0 then
    mode = ls[1]:match('^%d+') or mode
  end

  vim.fn.system({ 'git', '-C', root, 'update-index', '--add', '--cacheinfo', mode .. ',' .. oid .. ',' .. rel })
  if vim.v.shell_error ~= 0 then
    err('git update-index failed')
    return
  end

  local out = vim.fn.system({ 'git', '-C', root, 'approve', 'approve', rel })
  info(trim(out))

  -- Buffer now matches the index; let future external re-stages refresh it.
  if vim.b.git_approve_staged then
    vim.bo.modified = false
  end
  M.maybe_refresh()
end

return M
