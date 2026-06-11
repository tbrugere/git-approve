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
-- The git dir whose index we watch (set when a review opens), the libuv fs
-- watcher, and a polling timer used only as a fallback.
local watched_gitdir = nil
local fs_watcher = nil
local poll_timer = nil
-- forward declarations (defined below, used by review())
local start_watch
local start_poll

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

-- Tag the staged (right) buffer so the approve/refresh logic can find it.
local function mark_staged(buf, path)
  vim.b[buf].git_approve_path = path
  vim.b[buf].git_approve_staged = true
end

-- Open one tab for `path`. For a tracked file: HEAD (left) vs staged (right).
-- For an added file (no HEAD version) there is nothing to diff against, so just
-- show the staged content fullscreen. Returns the new tabpage handle, or nil.
local function open_diff(root, path)
  local staged = blob(root, '', path)
  if not staged then
    err('cannot read staged version of ' .. path)
    return
  end

  vim.cmd('tabnew')

  if not head_has(root, path) then
    -- Added file: staged content fullscreen, no empty companion.
    local rbuf = scratch(staged, path .. ' ◍staged (new)', path, true)
    vim.api.nvim_win_set_buf(0, rbuf)
    mark_staged(rbuf, path)
    return vim.api.nvim_get_current_tabpage()
  end

  -- Left: HEAD (read-only).
  local lbuf = scratch(blob(root, 'HEAD', path) or {}, path .. ' ◍HEAD', path, false)
  vim.api.nvim_win_set_buf(0, lbuf)
  vim.b[lbuf].git_approve_path = path
  vim.cmd('diffthis')

  -- Right: staged (editable, so it can be tweaked and re-staged). `rightbelow`
  -- forces the new window to the right regardless of the user's 'splitright'.
  vim.cmd('rightbelow vsplit')
  local rbuf = scratch(staged, path .. ' ◍staged', path, true)
  vim.api.nvim_win_set_buf(0, rbuf)
  mark_staged(rbuf, path)
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
  -- Watch this repo's git dir so external re-stages refresh the diff.
  watched_gitdir = git_dir(root) or watched_gitdir
  start_watch()
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

local function current_tab_has_staged()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.b[vim.api.nvim_win_get_buf(win)].git_approve_staged then
      return true
    end
  end
  return false
end

-- Cheap hook (watcher-, autocmd-, and timer-driven): refresh only when the tab has
-- a review diff and the index changed since last seen. The git dir is resolved
-- once (cached in `watched_gitdir`) so polling never shells out — it just stats.
function M.maybe_refresh()
  if not current_tab_has_staged() then
    return
  end
  local gd = watched_gitdir
  if not gd then
    local root = repo_root()
    gd = root and git_dir(root) or nil
    if not gd then
      return
    end
    watched_gitdir = gd
  end
  local st = uv.fs_stat(gd .. '/index')
  local mtime = st and (st.mtime.sec * 1000000000 + st.mtime.nsec) or 0
  if index_mtime[gd] == mtime then
    return
  end
  index_mtime[gd] = mtime
  refresh_staged()
end

-- Watch the git dir for index changes so re-stages refresh the diff instantly.
-- We watch the *directory*, not the index file: git replaces the index via an
-- atomic rename (index.lock -> index), which would break a watch bound to the
-- original file. maybe_refresh()'s mtime guard ignores unrelated .git churn.
-- Falls back to polling if the platform/filesystem can't start an fs event.
function start_watch()
  if not watched_gitdir then
    return
  end
  if fs_watcher then
    fs_watcher:stop()
    fs_watcher = nil
  end
  local w = uv.new_fs_event()
  local ok = w and w:start(watched_gitdir, {}, vim.schedule_wrap(function()
    M.maybe_refresh()
  end))
  if ok == 0 then
    fs_watcher = w
  else
    if w then
      pcall(function()
        w:stop()
      end)
    end
    start_poll()
  end
end

-- Polling fallback for when fs events aren't available (focus/buffer autocmds
-- are unreliable — terminal/tmux may not deliver them). The mtime guard keeps
-- each tick to a single stat.
function start_poll()
  if poll_timer then
    return
  end
  poll_timer = uv.new_timer()
  poll_timer:start(1000, 1000, vim.schedule_wrap(M.maybe_refresh))
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
