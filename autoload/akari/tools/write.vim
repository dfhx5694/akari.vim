vim9script

import autoload 'akari/utils/buffer.vim' as Buffer
import autoload 'akari/utils/text.vim' as Text

export def Run(input: dict<any>, session_state: dict<any>): dict<any>
  for key in ['path', 'content']
    if !has_key(input, key)
      return {ok: false, output: key .. ' is required'}
    endif
    if type(input[key]) != v:t_string
      return {ok: false, output: key .. ' must be a string'}
    endif
  endfor
  var rel: string = input.path
  if rel == ''
    return {ok: false, output: 'path is required'}
  endif
  var content: string = input.content
  var abs = Buffer.Path(rel)
  var existed = filereadable(abs)
  var buf = Buffer.Find(abs)
  if buf > 0
    if !getbufvar(buf, '&modifiable')
      return {ok: false, output: 'buffer is not modifiable: ' .. abs}
    endif
    var final_eol = content =~ '[\r\n]$'
    if !Buffer.ReplaceText(buf, content, final_eol)
      return {ok: false, output: 'failed to update buffer: ' .. abs}
    endif
    return {
      ok: true,
      output: 'updated buffer ' .. abs,
      created: !existed,
      source: 'buffer',
    }
  endif

  var parent = fnamemodify(abs, ':h')
  if parent != '' && parent != '.' && !isdirectory(parent)
    try
      mkdir(parent, 'p')
    catch
      return {ok: false, output: 'failed to create directory ' .. parent .. ': ' .. v:exception}
    endtry
    if !isdirectory(parent)
      return {ok: false, output: 'failed to create directory: ' .. parent}
    endif
  endif
  try
    if !Text.WriteDisk(abs, content)
      return {ok: false, output: 'write failed: ' .. abs}
    endif
  catch
    return {ok: false, output: 'write failed: ' .. v:exception}
  endtry
  var bytes = getfsize(abs)
  return {
    ok: true,
    output: existed ? printf('wrote %d bytes to %s', bytes, abs) : printf('created %s (%d bytes)', abs, bytes),
    created: !existed,
    source: 'file',
  }
enddef

export def GetTool(): dict<any>
  return {
    name: 'write',
    description: 'Create or overwrite a text file, creating missing parent directories. Use this for complete-file writes; use edit for a targeted replacement.',
    schema: {
      type: 'object',
      properties: {
        path: {type: 'string', description: 'File path, relative to the current working directory or absolute.'},
        content: {type: 'string', description: 'Complete text to write to the file.'},
      },
      required: ['path', 'content'],
    },
    execute: Run,
  }
enddef
