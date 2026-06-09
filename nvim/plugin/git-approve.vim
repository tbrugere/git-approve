" git-approve.vim — fugitive-flavored commands for the git-approve CLI.
"
" Requires: tpope/vim-fugitive and the `git-approve` executable on $PATH.
"
" Commands:
"   :GApproveReview   like `:Git difftool -y --cached`, but only staged files
"                     that are NOT approved (your review queue).
"   :GApprove  [path] approve PATH (default: the current file).
"   :GUnapprove [path] revoke PATH (default: the current file).
"   :GApproveStage    stage the current buffer's text into the index (without
"                     touching the working-tree file) and approve it.

if exists('g:loaded_git_approve')
  finish
endif
let g:loaded_git_approve = 1

" Staged-but-not-approved files (repo-root-relative paths), or [] on error.
function! s:Unapproved() abort
  let l:lines = systemlist('git-approve pending')
  if v:shell_error
    echohl ErrorMsg
    echom 'git-approve: ' . join(l:lines, ' ')
    echohl None
    return []
  endif
  return filter(l:lines, '!empty(v:val)')
endfunction

" The real file backing the current buffer (resolves fugitive:// buffers so
" :GApprove works from inside a difftool diff), as an absolute path.
function! s:CurrentFile() abort
  if exists('*FugitiveReal')
    let l:real = FugitiveReal(@%)
    if !empty(l:real)
      return l:real
    endif
  endif
  return expand('%:p')
endfunction

function! s:Review() abort
  let l:files = s:Unapproved()
  if empty(l:files)
    echo 'git-approve: nothing staged and unapproved'
    return
  endif
  " git-approve reads repo-root-relative paths; fugitive runs git from the work
  " tree root, so these pathspecs resolve correctly.
  execute 'Git difftool -y --cached -- '
        \ . join(map(copy(l:files), 'fnameescape(v:val)'), ' ')
endfunction

function! s:Run(subcmd, args) abort
  let l:target = empty(a:args) ? shellescape(s:CurrentFile()) : a:args
  if empty(l:target)
    echohl ErrorMsg | echom 'git-approve: no file' | echohl None
    return
  endif
  let l:out = system('git-approve ' . a:subcmd . ' ' . l:target)
  echo substitute(l:out, '\_s\+$', '', '')
endfunction

" Stage the current buffer's contents directly into the index and approve that
" path. The working-tree file is NOT modified: we hash the buffer to a blob and
" point the index entry at it, rather than writing the file and `git add`-ing.
function! s:StageApprove() abort
  let l:file = s:CurrentFile()
  if empty(l:file)
    echohl ErrorMsg | echom 'git-approve: no file' | echohl None
    return
  endif
  let l:dir = fnamemodify(l:file, ':h')
  let l:info = systemlist('git -C ' . shellescape(l:dir)
        \ . ' rev-parse --show-toplevel --show-prefix')
  if v:shell_error || empty(l:info)
    echohl ErrorMsg | echom 'git-approve: not in a git repository' | echohl None
    return
  endif
  let l:root = l:info[0]
  let l:rel = get(l:info, 1, '') . fnamemodify(l:file, ':t')
  let l:gitc = 'git -C ' . shellescape(l:root) . ' '

  " Serialize the buffer to a temp file (Vim's exact write logic, honoring
  " 'fileformat'/'fixendofline'), then hash it — the working tree is untouched.
  let l:tmp = tempname()
  execute 'silent keepalt write! ' . fnameescape(l:tmp)
  let l:oid = substitute(
        \ system(l:gitc . 'hash-object -w -- ' . shellescape(l:tmp)), '\_s\+$', '', '')
  call delete(l:tmp)
  if v:shell_error || empty(l:oid)
    echohl ErrorMsg | echom 'git hash-object failed' | echohl None
    return
  endif

  " Preserve the existing index mode if the path is tracked, else default.
  let l:mode = '100644'
  let l:ls = systemlist(l:gitc . 'ls-files -s -- ' . shellescape(l:rel))
  if !empty(l:ls)
    let l:mode = matchstr(l:ls[0], '^\d\+')
  endif

  " Point only the index entry at the new blob; the working tree stays as-is.
  call system(l:gitc . 'update-index --add --cacheinfo '
        \ . l:mode . ',' . l:oid . ',' . l:rel)
  if v:shell_error
    echohl ErrorMsg | echom 'git update-index failed' | echohl None
    return
  endif

  let l:out = system('cd ' . shellescape(l:root)
        \ . ' && git-approve approve ' . shellescape(l:rel))
  echo substitute(l:out, '\_s\+$', '', '')
endfunction

command! GApproveReview call s:Review()
command! -nargs=* -complete=file GApprove call s:Run('approve', <q-args>)
command! -nargs=* -complete=file GUnapprove call s:Run('revoke', <q-args>)
command! GApproveStage call s:StageApprove()
