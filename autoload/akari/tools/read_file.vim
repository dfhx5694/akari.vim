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

export def Run(input: dict<any>, session_state: dict<any>): dict<any>
  for key in ['path']
    if !has_key(input, key)
      return {ok: false, output: key .. ' is required'}
    endif
    if type(input[key]) != v:t_string
      return {ok: false, output: key .. ' must be a string'}
    endif
  endfor
  for key in ['start_line', 'max_lines']
    if has_key(input, key) && type(input[key]) != v:t_number
      return {ok: false, output: key .. ' must be an integer'}
    endif
  endfor
  var rel: string = input.path
  if rel == ''
    return {ok: false, output: 'path is required'}
  endif
  var abs = Buffer.Path(rel)
  return ReadFile(abs, input)
enddef

export def GetTool(): dict<any>
  return {
    name: 'read_file',
    description: 'Read a range of lines from a single file. A loaded buffer for the path takes precedence over disk contents. Only reads file contents: use the search tool to find matching lines and list_dir to list directory entries.',
    schema: {
      type: 'object',
      properties: {
        path: {type: 'string', description: 'File path, relative to the current working directory or absolute.'},
        start_line: {type: 'integer', description: 'First line to read, using 1-based numbering.'},
        max_lines: {type: 'integer', description: 'Maximum number of lines to read; capped at 500.'},
      },
      required: ['path'],
    },
    execute: Run,
  }
enddef
