vim9script

import autoload 'akari/utils/buffer.vim' as Buffer
import autoload 'akari/utils/files.vim' as Files

def Limit(input: dict<any>, key: string, fallback: number, maximum: number): number
  var value: number = get(input, key, fallback)
  return min([max([value, 1]), maximum])
enddef

def ListDir(abs: string, input: dict<any>): dict<any>
  if !isdirectory(abs)
    return {ok: false, output: 'directory not found: ' .. abs}
  endif
  var max_results = Limit(input, 'max_results', 200, 500)
  var entries: list<string> = []
  for item in Files.Files(abs, input)
    add(entries, isdirectory(item) ? item .. '/' : item)
    if len(entries) > max_results
      entries = entries[: max_results - 1]
      return {ok: true, output: join(entries, "\n"), entries: len(entries), truncated: true}
    endif
  endfor
  return {ok: true, output: empty(entries) ? '(empty directory)' : join(entries, "\n"), entries: len(entries), truncated: false}
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
  if has_key(input, 'include') && type(input.include) != v:t_string
    return {ok: false, output: 'include must be a string'}
  endif
  if has_key(input, 'max_results') && type(input.max_results) != v:t_number
    return {ok: false, output: 'max_results must be an integer'}
  endif
  if has_key(input, 'recursive') && type(input.recursive) != v:t_bool
    return {ok: false, output: 'recursive must be a boolean'}
  endif
  var rel: string = input.path
  if rel == ''
    return {ok: false, output: 'path is required'}
  endif
  var abs = Buffer.Path(rel)
  return ListDir(abs, input)
enddef

export def GetTool(): dict<any>
  return {
    name: 'list_dir',
    description: 'List entries of a directory, optionally filtered by a glob and optionally recursive. Directory entries end with a slash. Use read_file for file contents and search to find matching lines.',
    schema: {
      type: 'object',
      properties: {
        path: {type: 'string', description: 'Directory path, relative to the current working directory or absolute.'},
        include: {type: 'string', description: 'Optional file glob filter, for example *.vim.'},
        recursive: {type: 'boolean', description: 'List subdirectories recursively.'},
        max_results: {type: 'integer', description: 'Maximum listed entries; capped at 500.'},
      },
      required: ['path'],
    },
    execute: Run,
  }
enddef
