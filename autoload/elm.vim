let s:errors = []

function! s:elmOracle(...) abort
  let l:project = finddir('elm-stuff/..', '.;')
  if len(l:project) == 0
    echoerr '`elm-stuff` not found! run `elm install` for autocomplete.'
    return []
  endif

  let l:filename = expand('%:p')

  if a:0 == 0
    let l:oldiskeyword = &iskeyword
    " Some non obvious values used in 'iskeyword':
    "    @     = all alpha
    "    48-57 = numbers 0 to 9
    "    @-@   = character @
    "    124   = |
    setlocal iskeyword=@,48-57,@-@,_,-,~,!,#,$,%,&,*,+,=,<,>,/,?,.,\\,124,^
    let l:word = expand('<cword>')
    let &iskeyword = l:oldiskeyword
  else
    let l:word = a:1
  endif

  let l:infos = elm#Oracle(l:filename, l:word)
  if v:shell_error != 0
    call elm#util#EchoError("elm-oracle failed:\n\n", l:infos)
    return []
  endif

  let l:d = split(l:infos, '\n')
  if len(l:d) > 0
    return elm#util#DecodeJSON(l:d[0])
  endif

  return []
endf

" Vim command to format Elm files with elm-format
function! elm#Format() abort
  " check for elm-format
  if elm#util#CheckBin('elm-format', 'https://github.com/avh4/elm-format') ==# ''
    return
  endif

  " save cursor position, folds and many other things
    let l:curw = {}
    try
      mkview!
    catch
      let l:curw = winsaveview()
    endtry

    " save our undo file to be restored after we are done.
    let l:tmpundofile = tempname()
    exe 'wundo! ' . l:tmpundofile

  " write current unsaved buffer to a temporary file
  let l:tmpname = tempname() . '.elm'
  call writefile(getline(1, '$'), l:tmpname)

  " call elm-format on the temporary file
  let l:out = system('elm-format ' . l:tmpname . ' --output ' . l:tmpname)

  " if there is no error
  if v:shell_error == 0
    try | silent undojoin | catch | endtry

    " replace current file with temp file, then reload buffer
    let l:old_fileformat = &fileformat
    call rename(l:tmpname, expand('%'))
    silent edit!
    let &fileformat = l:old_fileformat
    let &syntax = &syntax
  elseif g:elm_format_fail_silently == 0
    call elm#util#EchoLater('EchoError', 'elm-format:', l:out)
  endif

    " save our undo history
    silent! exe 'rundo ' . l:tmpundofile
    call delete(l:tmpundofile)

  " restore our cursor/windows positions, folds, etc..
    if empty(l:curw)
      silent! loadview
    else
      call winrestview(l:curw)
    endif
endf

" Query elm-oracle and echo the type and docs for the word under the cursor.
function! elm#ShowDocs() abort
  " check for the elm-oracle binary
  if elm#util#CheckBin('elm-oracle', 'https://github.com/elmcast/elm-oracle') ==# ''
    return
  endif

  let l:response = s:elmOracle()

  if len(l:response) > 0
    let l:info = l:response[0]
    redraws! | echohl Identifier | echon l:info.fullName | echohl None | echon ' : ' | echohl Function | echon l:info.signature | echohl None | echon "\n\n" . l:info.comment
  else
    call elm#util#Echo('elm-oracle:', '...no match found')
  endif
endf

" Query elm-oracle and open the docs for the word under the cursor.
function! elm#BrowseDocs() abort
  " check for the elm-oracle binary
  if elm#util#CheckBin('elm-oracle', 'https://github.com/elmcast/elm-oracle') ==# ''
    return
  endif

  let l:response = s:elmOracle()

  if len(l:response) > 0
    let l:info = l:response[0]
    call elm#util#OpenBrowser(l:info.href)
  else
    call elm#util#Echo('elm-oracle:', '...no match found')
  endif
endf


function! elm#Syntastic(input) abort
  let l:fixes = []

  let l:bin = 'elm'
  let l:subcommand = 'make'
  let l:format = '--report=json'
  let l:input = shellescape(a:input)
  let l:output = '--output=' . shellescape(syntastic#util#DevNull())
  let l:command = l:bin . ' ' . l:subcommand . ' ' . l:format  . ' ' . l:input . ' ' . l:output
  let l:reports = s:ExecuteInRoot(l:command)

  for l:report in split(l:reports, '\n')
    if l:report[0] ==# '['
      for l:error in elm#util#DecodeJSON(l:report)
        if g:elm_syntastic_show_warnings == 0 && l:error.type ==? 'warning'
        else
          if a:input == l:error.file
            call add(s:errors, l:error)
            call add(l:fixes, {'filename': l:error.file,
                  \'valid': 1,
                  \'bufnr': bufnr('%'),
                  \'type': (l:error.type ==? 'error') ? 'E' : 'W',
                  \'lnum': l:error.region.start.line,
                  \'col': l:error.region.start.column,
                  \'text': l:error.overview})
          endif
        endif
      endfor
    endif
  endfor

  return l:fixes
endf

function! elm#Build(input, output, bin) abort
  let s:errors = []
  let l:fixes = []
  let l:rawlines = []

  let l:subcommand = 'make'
  let l:format = '--report=json'
  let l:input = shellescape(a:input)
  let l:output = '--output=' . shellescape(a:output)
  let l:command = a:bin . ' ' . l:subcommand . ' ' . l:format  . ' ' . l:input . ' ' . l:output
  let l:reports = s:ExecuteInRoot(l:command)

  " If we hit the common 'elm: not enough bytes' error then we delete the
  " elm-stuff directory and rebuild.
  "
  " As this is a bit dangerous we make it opt in via a config option
  if l:reports =~? '^elm: not enough bytes.*' && g:elm_delete_elm_stuff_on_fail == 1
    call elm#util#Echo('elm make:', 'deleting and rebuilding...')
    call s:ExecuteInRoot('rm -fr ./elm-stuff')
    let l:reports = s:ExecuteInRoot(l:command)
  endif

  if l:reports !=# ''
    let l:json = elm#util#DecodeJSON(l:reports)

    " Check to see if the error message is complaining about 'import Test'
    " which means that we're trying to build a file which needs test
    " dependencies and so we need to build with 'elm-test make' instead
    "
    " This could fail if there are other test dependencies and the compiler
    " complains about one of these others first. It seems to be based on
    " reverse source ordering of imports. Maybe there is a better approach?
    " I'm not so keen on doing a check for the directory as it is possible to
    " define tests outside the 'tests' directory as long as they are imported
    " there, I believe.
    if l:json.type ==# 'error' && l:json.title ==# 'UNKNOWN IMPORT'
        let l:failed_import = get(l:json.message, 1).string
        if l:failed_import ==# 'import Test'
          " Simple check to try to prevent recursive loop
          " if something goes wrong
          if a:bin ==# 'elm-test'
            return []
          else
            return elm#Build(a:input, a:output, 'elm-test')
          endif

        else
          " If it isn't 'import Test' then assume it is just a general import
          " error and report the file it happens in
          let l:messages = l:json.message
          let l:num_messages = len(l:messages)

          let l:count = 0
          let l:string_messages = []
          " Loop over the messages treating array entries differently if they
          " are a string versus, not a string.
          while l:count < l:num_messages
            let l:message = get(l:messages, l:count)
            if type(l:message) == type("")
              call add(l:string_messages, l:message)
              call add(l:rawlines, l:message)
            else
              " Extract the content from the 'string' attribute of the
              " highlight object
              call add(l:string_messages, l:message.string)
              call add(l:rawlines, l:message.string)
            end

            let l:count += 1
          endwhile

          " Extract the first line line of the error to use as the 'text'
          " attribute in the quick fix display. We take the first entry from
          " the messages array but that can have multiple lines in it so we
          " split on '\n' and take the first part and then add the import name
          " from the next entry of the messages
          let l:intro = get(split(get(l:messages, 0), '\n'), 0)
          let l:module_name = substitute(l:failed_import, 'import ', '', '')
          let l:first_line = l:intro . ' ' . l:module_name

          " We store the full error in s:errors so that we can display that to
          " the user if they request. The new lines are embedded in the
          " entries so we just join on nothing.
          let l:error_details = join(l:string_messages, "")

          " Use a pattern in the quick-fix entry so that we jump to the write
          " line in the file. The error message does not provide a line number
          let l:search_pattern = l:failed_import . '\( \|$\)'

          call add(s:errors, l:error_details)
          call add(l:fixes, {
                \'filename': l:json.path,
                \'valid': 1,
                \'type': 'E',
                \'pattern': l:search_pattern,
                \'text': l:first_line})
        endif
    " Check it is the json output that we're expecting
    elseif l:json.type ==# 'compile-errors'

      " Iterate over the reports in the output
      for l:report in l:json.errors

        " Iterate over the errors in the report
        for l:error in l:report.problems

          " Look at the 'message' entry in each 'problem'. The message entry
          " is an array of pure strings and 'highlight' objects. The
          " highlight objects have their contents in a 'string' attribute
          let l:messages = l:error.message
          let l:num_messages = len(l:messages)

          let l:count = 0
          let l:string_messages = []
          " Loop over the messages treating array entries differently if they
          " are a string versus, not a string.
          while l:count < l:num_messages
            let l:message = get(l:messages, l:count)
            if type(l:message) == type("")
              call add(l:string_messages, l:message)
              call add(l:rawlines, l:message)
            else
              " Extract the content from the 'string' attribute of the
              " highlight object
              call add(l:string_messages, l:message.string)
              call add(l:rawlines, l:message.string)
            end

            let l:count += 1
          endwhile

          " Extract the first line line of the error to use as the 'text'
          " attribute in the quick fix display. We take the first entry from
          " the messages array but that can have multiple lines in it so we
          " split on '\n' and take the first part
          let l:first_line = get(split(get(l:messages, 0), '\n'), 0)

          " We store the full error in s:errors so that we can display that to
          " the user if they request. The new lines are embedded in the
          " entries so we just join on nothing.
          let l:error_details = join(l:string_messages, "")

          call add(s:errors, l:error_details)
          call add(l:fixes, {
                \'filename': l:report.path,
                \'valid': 1,
                \'type': 'E',
                \'lnum': l:error.region.start.line,
                \'col': l:error.region.start.column,
                \'text': l:first_line})
        endfor
      endfor
    endif
  endif

  let l:details = join(l:rawlines, "\n")
  let l:lines = split(l:details, "\n")
  if !empty(l:lines)
    let l:overview = l:lines[0]
  else
    let l:overview = ''
  endif

  if l:details ==# '' || l:details =~? '^Successfully.*'
  else
    call add(s:errors, {'overview': l:details, 'details': l:details})
  endif

  return l:fixes
endf

" Make the given file, or the current file if none is given.
function! elm#Make(...) abort
  if elm#util#CheckBin('elm', 'http://elm-lang.org/install') ==# ''
    return
  endif

  call elm#util#Echo('elm make:', 'building...')

  let l:input = (a:0 == 0) ? expand('%:p') : a:1
  let l:bin = 'elm' " assume we're not building a test file
  let l:fixes = elm#Build(l:input, g:elm_make_output_file, 'elm')

  if len(l:fixes) > 0
    call elm#util#EchoWarning('', 'found ' . len(l:fixes) . ' errors')

    call setqflist(l:fixes, 'r')
    cwindow

    if get(g:, 'elm_jump_to_error', 1)
      ll 1
    endif
  else
    call elm#util#EchoSuccess('', 'Sucessfully compiled')

    call setqflist([])
    cwindow
  endif
endf

" Show the detail of the current error in the quickfix window.
function! elm#ErrorDetail() abort
  if !empty(filter(tabpagebuflist(), 'getbufvar(v:val, "&buftype") ==? "quickfix"'))
    exec ':copen'
    let l:linenr = line('.')
    exec ':wincmd p'
    if len(s:errors) > 0
      let l:detail = s:errors[l:linenr-1]
      echo l:detail
    endif
  endif
endf

" Open the elm repl in a subprocess.
function! elm#Repl() abort
  " check for the elm-repl binary
  if elm#util#CheckBin('elm-repl', 'http://elm-lang.org/install') ==# ''
    return
  endif

  if has('nvim')
    term('elm-repl')
  else
    !elm-repl
  endif
endf

function! elm#Oracle(filepath, word) abort
  let l:bin = 'elm-oracle'
  let l:filepath = shellescape(a:filepath)
  let l:word = shellescape(a:word)
  let l:command = l:bin . ' ' . l:filepath . ' ' . l:word
  return s:ExecuteInRoot(l:command)
endfunction

let s:fullComplete = ''

" Complete the current token using elm-oracle
function! elm#Complete(findstart, base) abort
" a:base is unused, but the callback function for completion expects 2 arguments
  if a:findstart
    let l:line = getline('.')

    let l:idx = col('.') - 1
    let l:start = 0
    while l:idx > 0 && l:line[l:idx - 1] =~# '[a-zA-Z0-9_\.]'
      if l:line[l:idx - 1] ==# '.' && l:start == 0
        let l:start = l:idx
      endif
      let l:idx -= 1
    endwhile

    if l:start == 0
      let l:start = l:idx
    endif

    let s:fullComplete = l:line[l:idx : col('.')-2]

    return l:start
  else
    " check for the elm-oracle binary
    if elm#util#CheckBin('elm-oracle', 'https://github.com/elmcast/elm-oracle') ==# ''
      return []
    endif

    let l:res = []
    let l:response = s:elmOracle(s:fullComplete)

    let l:detailed = get(g:, 'elm_detailed_complete', 0)

    for l:r in l:response
      let l:menu = ''
      if l:detailed
        let l:menu = ': ' . l:r.signature
      endif
      call add(l:res, {'word': l:r.name, 'menu': l:menu})
    endfor

    return l:res
  endif
endf

" If the current buffer contains a consoleRunner, run elm-test with it.
" Otherwise run elm-test in the root of your project which deafults to
" running 'elm-test tests/TestRunner'.
function! elm#Test() abort
  if elm#util#CheckBin('elm-test', 'https://github.com/rtfeldman/node-elm-test') ==# ''
    return
  endif

  if match(getline(1, '$'), 'consoleRunner') < 0
    let l:out = s:ExecuteInRoot('elm-test')
    call elm#util#EchoSuccess('elm-test', l:out)
  else
    let l:filepath = shellescape(expand('%:p'))
    let l:out = s:ExecuteInRoot('elm-test ' . l:filepath)
    call elm#util#EchoSuccess('elm-test', l:out)
  endif
endf

" Returns the closest parent with an elm.json file.
function! elm#FindRootDirectory() abort
  let l:elm_root = getbufvar('%', 'elmRoot')
  if empty(l:elm_root)
    let l:current_file = expand('%:p')
    let l:dir_current_file = fnameescape(fnamemodify(l:current_file, ':h'))
    let l:match = findfile('elm.json', l:dir_current_file . ';')
    if empty(l:match)
      let l:elm_root = ''
    else
      let l:elm_root = fnamemodify(l:match, ':p:h')
    endif

    if !empty(l:elm_root)
      call setbufvar('%', 'elmRoot', l:elm_root)
    endif
  endif
  return l:elm_root
endfunction

" Executes a command in the project directory.
function! s:ExecuteInRoot(cmd) abort
  let l:cd = exists('*haslocaldir') && haslocaldir() ? 'lcd ' : 'cd '
  let l:current_dir = getcwd()
  let l:root_dir = elm#FindRootDirectory()

  try
    execute l:cd . fnameescape(l:root_dir)
    let l:out = system(a:cmd)
  finally
    execute l:cd . fnameescape(l:current_dir)
  endtry

  return l:out
endfunction
