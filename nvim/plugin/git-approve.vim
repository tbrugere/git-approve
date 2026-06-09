" git-approve.vim — fugitive-flavored commands for the git-approve CLI.
"
" Requires: tpope/vim-fugitive and the `git-approve` executable on $PATH.
"
" Commands:
"   :GApproveReview   like `:Git difftool -y --cached`, but only staged files
"                     that are NOT approved (your review queue).
"   :GApprove  [path] approve PATH (default: the current file).
"   :GUnapprove [path] revoke PATH (default: the current file).
"   :GApproveStage    save the current buffer, stage it, and approve it.

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

" Save the current buffer, stage it (fugitive's :Gwrite), and approve it.
function! s:StageApprove() abort
  let l:file = s:CurrentFile()
  if empty(l:file)
    echohl ErrorMsg | echom 'git-approve: no file' | echohl None
    return
  endif
  Gwrite
  call s:Run('approve', '')
endfunction

command! GApproveReview call s:Review()
command! -nargs=* -complete=file GApprove call s:Run('approve', <q-args>)
command! -nargs=* -complete=file GUnapprove call s:Run('revoke', <q-args>)
command! GApproveStage call s:StageApprove()
