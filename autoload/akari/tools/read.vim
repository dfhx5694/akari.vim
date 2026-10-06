vim9script

import autoload 'akari/utils/buffer.vim' as Buffer

def Limit(input: dict<any>, key: string, fallback: number, maximum: number): number
  var value: number = get(input, key, fallback)
  return min([max([value, 1]), maximum])
enddef

def ReadFile(abs: string, input: dict<any>): dict<any>
  var buf = Buffer.Find(abs)
  if buf <= 0 && !filereadable(abs)
    return {ok: false, output: 'file not found: ' .. abs}
  endif
  var lines = buf > 0 ? Buffer.Lines(buf) : readfile(abs)
  var source = buf > 0 ? 'buffer' : 'file'
  var total = len(lines)
  var start_line = Limit(input, 'start_line', 1, 999999999)
  var max_lines = Limit(input, 'max_lines', 200, 500)
  if start_line > total
    return {ok: true, output: '(empty — start_line beyond file)', start_line: start_line, total_lines: total, truncated: false, source: source}
  endif
  var end_line = min([start_line + max_lines - 1, total])
  var content = join(lines[start_line - 1 : end_line - 1], "\n")
  var result: dict<any> = {
    ok: true,
    output: content,
    start_line: start_line,
    end_line: end_line,
    total_lines: total,
    truncated: end_line < total,
    source: source,
  }
  if end_line < total
    result.next_start_line = end_line + 1
  endif
  return result
enddef

def Files(abs: string, input: dict<any>): list<string>
  var include = get(input, 'include', '*')
  var recursive = get(input, 'recursive', false)
  var suffix = recursive ? '/**/' .. include : '/' .. include
  return glob(abs .. suffix, false, true)
enddef

def ReadableFiles(abs: string, input: dict<any>): list<string>
  var files: list<string> = []
  for file in Files(abs, input)
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
  var lines = systemlist(args)
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

def Search(abs: string, input: dict<any>): dict<any>
  var pattern = get(input, 'pattern', '')
  if pattern == ''
    return {ok: false, output: 'pattern is required for search mode'}
  endif
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

def ListDir(abs: string, input: dict<any>): dict<any>
  if !isdirectory(abs)
    return {ok: false, output: 'directory not found: ' .. abs}
  endif
  var max_results = Limit(input, 'max_results', 200, 500)
  var entries: list<string> = []
  for item in Files(abs, input)
    add(entries, isdirectory(item) ? item .. '/' : item)
    if len(entries) > max_results
      entries = entries[: max_results - 1]
      return {ok: true, output: join(entries, "\n"), entries: len(entries), truncated: true}
    endif
  endfor
  return {ok: true, output: empty(entries) ? '(empty directory)' : join(entries, "\n"), entries: len(entries), truncated: false}
enddef

def BufferBytes(buf: number, lines: list<string>, newline: string): number
  if len(lines) == 1 && lines[0] == ''
    return 0
  endif
  var text = join(lines, newline)
  if getbufvar(buf, '&endofline')
    text ..= newline
  endif
  var file_encoding = getbufvar(buf, '&fileencoding')
  if file_encoding == ''
    file_encoding = &encoding
  endif
  var encoded = has('iconv') ? iconv(text, &encoding, file_encoding) : text
  var bytes = strlen(encoded)
  if getbufvar(buf, '&bomb') && has('iconv')
    bytes += strlen(iconv("\ufeff", &encoding, file_encoding))
  endif
  return bytes
enddef

def Count(abs: string, input: dict<any>): dict<any>
  var buf = Buffer.Find(abs)
  if buf > 0
    var lines = Buffer.Lines(buf)
    var line_count = len(lines)
    var words = 0
    for line in lines
      var trimmed = trim(line)
      if trimmed != ''
        words += len(split(trimmed, '\s\+', 1))
      endif
    endfor
    var newline = getbufvar(buf, '&fileformat') == 'dos' ? "\r\n" : getbufvar(buf, '&fileformat') == 'mac' ? "\r" : "\n"
    var bytes = BufferBytes(buf, lines, newline)
    return {
      ok: true,
      output: printf('lines: %d\nwords: %d\nbytes: %d', line_count, words, bytes),
      lines: line_count,
      words: words,
      bytes: bytes,
      files: 1,
      source: 'buffer',
    }
  endif
  var files: list<string> = []
  if filereadable(abs)
    files = [abs]
  elseif isdirectory(abs)
    files = ReadableFiles(abs, input)
  endif
  if empty(files)
    return {ok: false, output: 'file or directory not found: ' .. abs}
  endif
  var lines = 0
  var words = 0
  var bytes = 0
  for file in files
    var content = readfile(file)
    lines += len(content)
    bytes += getfsize(file)
    for line in content
      var trimmed = trim(line)
      if trimmed != ''
        words += len(split(trimmed, '\s\+', 1))
      endif
    endfor
  endfor
  return {
    ok: true,
    output: printf('lines: %d\nwords: %d\nbytes: %d', lines, words, bytes),
    lines: lines,
    words: words,
    bytes: bytes,
    files: len(files),
  }
enddef

export def Run(input: dict<any>, session_state: dict<any>): dict<any>
  for key in ['path', 'mode', 'pattern', 'include']
    if has_key(input, key) && type(input[key]) != v:t_string
      return {ok: false, output: key .. ' must be a string'}
    endif
  endfor
  for key in ['start_line', 'max_lines', 'max_results']
    if has_key(input, key) && type(input[key]) != v:t_number
      return {ok: false, output: key .. ' must be an integer'}
    endif
  endfor
  if has_key(input, 'recursive') && type(input.recursive) != v:t_bool
    return {ok: false, output: 'recursive must be a boolean'}
  endif
  var rel = get(input, 'path', '')
  if rel == ''
    return {ok: false, output: 'path is required'}
  endif
  var abs = Buffer.Path(rel)
  var mode: string = get(input, 'mode', 'file')
  if mode == 'file'
    return ReadFile(abs, input)
  elseif mode == 'search'
    return Search(abs, input)
  elseif mode == 'list'
    return ListDir(abs, input)
  elseif mode == 'count'
    return Count(abs, input)
  endif
  return {ok: false, output: 'unknown read mode: ' .. mode}
enddef

export def GetTool(): dict<any>
  return {
    name: 'read',
    description: 'Read files and directories. For a file path, loaded buffer contents take precedence over disk contents. Use mode=file for file contents, mode=search to find matching lines, mode=list to list directory entries, or mode=count for line, word, and byte statistics.',
    schema: {
      type: 'object',
      properties: {
        mode: {type: 'string', description: 'Operation: file (default), search, list, or count.'},
        path: {type: 'string', description: 'File or directory path, relative to the current working directory or absolute.'},
        pattern: {type: 'string', description: 'Pattern for search mode. rg syntax is used when available; otherwise Vim regular expression syntax is used.'},
        include: {type: 'string', description: 'Optional file glob filter, for example *.vim.'},
        recursive: {type: 'boolean', description: 'Search or list subdirectories recursively.'},
        start_line: {type: 'integer', description: 'First line to read in file mode, using 1-based numbering.'},
        max_lines: {type: 'integer', description: 'Maximum number of lines to read in file mode; capped at 500.'},
        max_results: {type: 'integer', description: 'Maximum search or list results; capped at 500.'},
      },
      required: ['path'],
    },
    execute: Run,
  }
enddef
