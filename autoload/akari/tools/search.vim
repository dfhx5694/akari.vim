vim9script

import autoload 'akari/utils/buffer.vim' as Buffer
import autoload 'akari/utils/files.vim' as Files

def Limit(input: dict<any>, key: string, fallback: number, maximum: number): number
  var value: number = get(input, key, fallback)
  return min([max([value, 1]), maximum])
enddef

def ReadableFiles(abs: string, input: dict<any>): list<string>
  var files: list<string> = []
  for file in Files.Files(abs, input)
    if filereadable(file)
      add(files, file)
    endif
  endfor
  return files
enddef

def SearchRg(abs: string, input: dict<any>, pattern: string, max_results: number): any
  if !executable('rg')
    return null
  endif
  var args: list<string> = ['rg', '--color=never', '--no-heading', '--line-number', '--with-filename', '--max-count', string(max_results + 1)]
  if isdirectory(abs) && !get(input, 'recursive', false)
    add(args, '--max-depth')
    add(args, '1')
  endif
  var include = get(input, 'include', '')
  if include != '' && include != '*'
    add(args, '--glob')
    add(args, include)
  endif
  add(args, '--')
  add(args, pattern)
  add(args, abs)
  var lines = systemlist(join(mapnew(args, (_: number, arg: string): string => shellescape(arg)), ' '))
  if v:shell_error > 1
    return null
  endif
  var truncated = len(lines) > max_results
  if truncated
    lines = lines[: max_results - 1]
  endif
  return {
    ok: true,
    output: empty(lines) ? '(no matches)' : join(lines, "\n"),
    matches: len(lines),
    truncated: truncated,
  }
enddef

def Search(abs: string, input: dict<any>, pattern: string): dict<any>
  var max_results = Limit(input, 'max_results', 200, 500)
  var buf = Buffer.Find(abs)
  if buf > 0
    var lines = Buffer.Lines(buf)
    var matches: list<string> = []
    var line_no = 0
    for line in lines
      line_no += 1
      var matched = false
      try
        matched = line =~ pattern
      catch
        return {ok: false, output: 'invalid search pattern: ' .. pattern}
      endtry
      if matched
        add(matches, abs .. ':' .. string(line_no) .. ': ' .. line)
        if len(matches) > max_results
          matches = matches[: max_results - 1]
          return {ok: true, output: join(matches, "\n"), matches: len(matches), truncated: true, source: 'buffer'}
        endif
      endif
    endfor
    return {ok: true, output: empty(matches) ? '(no matches)' : join(matches, "\n"), matches: len(matches), truncated: false, source: 'buffer'}
  endif
  var rg_result = SearchRg(abs, input, pattern, max_results)
  if rg_result != null
    return rg_result
  endif
  var files: list<string> = []
  if filereadable(abs)
    files = [abs]
  elseif isdirectory(abs)
    files = ReadableFiles(abs, input)
  endif
  if empty(files)
    return {ok: true, output: '(no files found)', matches: 0, truncated: false}
  endif
  var matches: list<string> = []
  for file in files
    var line_no = 0
    for line in readfile(file)
      line_no += 1
      var matched = false
      try
        matched = line =~ pattern
      catch
        return {ok: false, output: 'invalid search pattern: ' .. pattern}
      endtry
      if matched
        add(matches, file .. ':' .. string(line_no) .. ': ' .. line)
        if len(matches) > max_results
          matches = matches[: max_results - 1]
          return {ok: true, output: join(matches, "\n"), matches: len(matches), truncated: true}
        endif
      endif
    endfor
  endfor
  return {ok: true, output: empty(matches) ? '(no matches)' : join(matches, "\n"), matches: len(matches), truncated: false}
enddef

export def Run(input: dict<any>, session_state: dict<any>): dict<any>
  for key in ['pattern', 'path']
    if !has_key(input, key)
      return {ok: false, output: key .. ' is required'}
    endif
    if type(input[key]) != v:t_string
      return {ok: false, output: key .. ' must be a string'}
    endif
  endfor
  if has_key(input, 'include') && type(input.include) != v:t_string
    return {ok: false, output: 'include must be a string'}
  endif
  if has_key(input, 'max_results') && type(input.max_results) != v:t_number
    return {ok: false, output: 'max_results must be an integer'}
  endif
  if has_key(input, 'recursive') && type(input.recursive) != v:t_bool
    return {ok: false, output: 'recursive must be a boolean'}
  endif
  var pattern: string = input.pattern
  if pattern == ''
    return {ok: false, output: 'pattern is required'}
  endif
  var rel: string = input.path
  if rel == ''
    return {ok: false, output: 'path is required'}
  endif
  var abs = Buffer.Path(rel)
  return Search(abs, input, pattern)
enddef

export def GetTool(): dict<any>
  return {
    name: 'search',
    description: 'Find lines matching a pattern in a file or directory. rg syntax is used when available; otherwise Vim regular expression syntax is used. A loaded buffer for a file path takes precedence over disk contents.',
    schema: {
      type: 'object',
      properties: {
        pattern: {type: 'string', description: 'Pattern to match. rg syntax is used when available; otherwise Vim regular expression syntax is used.'},
        path: {type: 'string', description: 'File or directory path, relative to the current working directory or absolute.'},
        include: {type: 'string', description: 'Optional file glob filter, for example *.vim.'},
        recursive: {type: 'boolean', description: 'Search subdirectories recursively.'},
        max_results: {type: 'integer', description: 'Maximum search results; capped at 500.'},
      },
      required: ['pattern', 'path'],
    },
    execute: Run,
  }
enddef
