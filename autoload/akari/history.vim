vim9script

import autoload 'akari/config.vim'

var streaming: dict<any> = {}

def IsMarkerLike(line: string): bool
  return strpart(line, 0, 3) == '>>>' || strpart(line, 0, 3) == '<<<'
enddef

def EscapeLine(line: string): string
  if strpart(line, 0, 1) == '\' || IsMarkerLike(line)
    return '\' .. line
  endif
  return line
enddef

def EncodeContent(content: string, metadata: bool = true): list<string>
  var lines = split(content, "\n", true)

  var index = 0
  while index < len(lines)
    lines[index] = EscapeLine(lines[index])
    index += 1
  endwhile
  if !metadata && !empty(lines) && lines[0] =~ '^\s*{' && lines[0] =~ '"\(id\|phase\|status\|content\)"\s*:'
    lines[0] = '\' .. lines[0]
  endif
  return lines
enddef

def DecodeContent(lines: list<string>): string
  var decoded: list<string> = []
  for line in lines
    var decoded_line = line
    if strpart(decoded_line, 0, 1) == '\'
      var unescaped = strpart(decoded_line, 1)
      if IsMarkerLike(unescaped) || strpart(unescaped, 0, 1) == '\' || unescaped =~ '^\s*{'
        decoded_line = unescaped
      endif
    endif
    add(decoded, decoded_line)
  endfor
  return join(decoded, "\n")
enddef


def SetBufferLines(buf: number, lines: list<string>): bool
  var buffer_lines = lines
  if empty(buffer_lines)
    buffer_lines = ['']
  endif
  var old_count = len(getbufline(buf, 1, '$'))
  if setbufline(buf, 1, buffer_lines) != 0
    return false
  endif
  if old_count > len(buffer_lines) && deletebufline(buf, len(buffer_lines) + 1, old_count) != 0

    return false
  endif

  return true
enddef

# The pending user input is the trailing region of the buffer when the last
# marker is ">>> user". It stays raw (verbatim) in the buffer and is only
# escaped when another block is appended after it, so no external state is
# needed to remember where it is.
def PendingStart(lines: list<string>): number
  var index = len(lines) - 1
  while index >= 0
    var match = matchlist(lines[index], '^\(>>>\|<<<\) \(system\|user\|assistant\|tool\|think\|reasoning\)\s*$')
    if !empty(match)
      return match[1] == '>>>' && match[2] == 'user' ? index + 1 : -1
    endif
    index -= 1
  endwhile
  return -1
enddef

def SealPending(lines: list<string>): void
  var index = PendingStart(lines)
  if index < 0
    return
  endif
  while index < len(lines)
    lines[index] = EscapeLine(lines[index])
    index += 1
  endwhile
enddef

def LastRole(lines: list<string>): string
  var index = len(lines) - 1
  while index >= 0
    var match = matchlist(lines[index], '^\(>>>\|<<<\) \(system\|user\|assistant\|tool\|think\|reasoning\)\s*$')
    if !empty(match)
      return match[2]
    endif
    index -= 1
  endwhile
  return ''
enddef

def AddMarker(lines: list<string>, role: string): void
  var last_role = LastRole(lines)
  if (role == 'user' && last_role != '') || (role != 'user' && last_role == 'user')
    add(lines, '')
  endif
  var marker = role == 'system' || role == 'user' ? '>>> ' : '<<< '
  add(lines, marker .. role)
enddef

def BoundaryContent(role: string, next_role: string, content: list<string>): list<string>
  var result = copy(content)
  if (role == 'user' || next_role == 'user') && !empty(result) && result[-1] == ''
    remove(result, len(result) - 1)
  endif
  return result
enddef

export def TargetBuffer(): number
  var buf = bufnr()
  if getbufvar(buf, '&filetype') == 'akari'
    return buf
  endif
  return get(g:, 'akari_last_buffer', buf)
enddef

export def NewSession(): void
  var options = config.Options()
  execute('new ' .. rand() .. '.akari')
  setlocal filetype=akari
  var lines: list<string> = []
  var system: string = options.system_prompt
  var instructions: any = options.instructions_file
  var instruction_text: list<string> = []
  var paths: list<string> = type(instructions) == v:t_string ? [instructions] : instructions
  for path in paths
    if path != '' && filereadable(expand(path))
      if !empty(instruction_text)
        add(instruction_text, '')
      endif
      extend(instruction_text, readfile(expand(path)))
    endif
  endfor
  if !empty(instruction_text)
    if system != ''
      system ..= "\n\n"
    endif
    system ..= join(instruction_text, "\n")
  endif
  if system != ''
    add(lines, '>>> system')
    extend(lines, EncodeContent(system))
  endif

  AddMarker(lines, 'user')
  add(lines, '')
  setline(1, lines)
  cursor('$', 1)
enddef


export def ValidateAssistantMetadata(message: dict<any>): void
  if has_key(message, 'status') && (type(message.status) != v:t_string
      || index(['completed', 'incomplete', 'in_progress'], message.status) < 0)
    throw 'akari: assistant status must be completed, incomplete or in_progress'
  endif
  for field in ['id', 'phase']
    if has_key(message, field)
      var value = message[field]
      if field == 'phase' && value == null
        continue
      endif
      if type(value) != v:t_string || trim(value) == ''
        throw 'akari: assistant ' .. field .. ' must be a non-empty string' .. (field == 'phase' ? ' or null' : '')
      endif
    endif
  endfor
enddef

# Compact descriptors index the plain body by UTF-8 byte length, without storing
# text twice. Missing descriptors retain the legacy single output_text format.
export def AssistantContent(message: dict<any>): list<dict<any>>
  ValidateAssistantMetadata(message)
  var text = get(message, 'content', '')
  if type(text) != v:t_string
    throw 'akari: assistant content must be a string'
  endif
  if !has_key(message, 'content_parts')
    return [{type: 'output_text', text: text}]
  endif
  var descriptors = message.content_parts
  if type(descriptors) != v:t_list || empty(descriptors)
    throw 'akari: assistant content metadata must be a non-empty list'
  endif
  var parts: list<dict<any>> = []
  var offset = 0
  for part in descriptors
    if type(part) != v:t_dict || len(part) != 2
        || index(['output_text', 'refusal'], get(part, 'type', '')) < 0
        || type(get(part, 'length', null)) != v:t_number || part.length < 0
        || part.length > strlen(text) - offset
      throw 'akari: invalid assistant content descriptor'
    endif
    var value = strpart(text, offset, part.length)
    offset += part.length
    # Round-trip the byte offset through the original string, counting combining
    # codepoints separately. Never infer a boundary from a truncated prefix.
    if offset < strlen(text) && byteidxcomp(text, charidx(text, offset, true)) != offset
      throw 'akari: assistant content descriptor splits a UTF-8 character'
    endif
    add(parts, part.type == 'refusal' ? {type: 'refusal', refusal: value} : {type: 'output_text', text: value})
  endfor
  if offset != strlen(text)
    throw 'akari: assistant content descriptor lengths do not match body'
  endif
  return parts
enddef

def BuildMessage(role: string, text: string, block_line: number, has_metadata: bool = true): dict<any>
  if role == 'assistant' && has_metadata
    var lines = split(text, "\n", true)
    var metadata: any = null
    try
      metadata = json_decode(lines[0])
    catch
    endtry
    if type(metadata) == v:t_dict && !empty(filter(keys(metadata), (_, key) => index(['id', 'phase', 'status', 'content'], key) >= 0))
      for [key, value] in items(metadata)
        if index(['id', 'phase', 'status', 'content'], key) < 0
            || (key != 'content' && type(value) != v:t_string && !(key == 'phase' && value == null))
          throw printf('akari: invalid assistant metadata at line %d', block_line)
        endif
      endfor
      if has_key(metadata, 'content')
        metadata.content_parts = remove(metadata, 'content')
      endif
      var message = extend(metadata, {role: role, content: join(lines[1 :], "\n")})
      try
        AssistantContent(message)
      catch
        throw printf('akari: invalid assistant metadata at line %d: %s', block_line, v:exception)
      endtry
      return message
    endif
  endif
  if role != 'tool' && role != 'reasoning'
    return {role: role, content: text}
  endif

  var tool: any
  try
    tool = json_decode(text)
  catch
    throw printf('akari: invalid %s JSON at line %d', role, block_line)
  endtry
  if type(tool) != v:t_dict
    throw printf('akari: %s block at line %d must contain a JSON object', role, block_line)
  endif
  tool.role = role
  return tool
enddef

export def Messages(buf: number): list<dict<any>>
  if !bufexists(buf) || getbufvar(buf, '&filetype') != 'akari'
    echoerr 'akari: no history buffer'
  endif
  var lines = getbufline(buf, 1, '$')
  var pending = PendingStart(lines)
  var messages: list<dict<any>> = []
  var role = ''
  var content: list<string> = []
  var line_number = 0
  var block_line = 0
  for line in lines
    line_number += 1
    if pending > 0 && line_number > pending
      add(content, line)
      continue
    endif
    var match = matchlist(line, '^\(>>>\|<<<\) \(system\|user\|assistant\|tool\|think\|reasoning\)\s*$')
    if !empty(match)
      var message_content = BoundaryContent(role, match[2], content)
      var current_text = DecodeContent(message_content)
      if role != '' && current_text != ''
        add(messages, BuildMessage(role, current_text, block_line, !empty(content) && strpart(content[0], 0, 1) != '\'))
      elseif role == 'tool' || role == 'reasoning'
        throw printf('akari: empty tool block at line %d', block_line)
      endif
      role = match[2]
      block_line = line_number
      content = []
    elseif line =~ '^\(>>>\|<<<\)'
      throw printf('akari: invalid history marker at line %d: %s', line_number, line)
    elseif role == ''
      if line != ''
        throw printf('akari: text outside history block at line %d', line_number)
      endif
    else
      add(content, line)
    endif
  endfor
  var final_text = pending > 0 ? join(content, "\n") : DecodeContent(content)
  if role != '' && final_text != ''
    add(messages, BuildMessage(role, final_text, block_line, !empty(content) && strpart(content[0], 0, 1) != '\'))
  elseif role == 'tool' || role == 'reasoning'
    throw printf('akari: empty tool block at line %d', block_line)
  endif
  return messages
enddef

export def Append(role: string, content: string, buf: number, metadata: bool = false): void
  if !bufexists(buf) || getbufvar(buf, '&filetype') != 'akari'
    echoerr 'akari: no history buffer'
    return
  endif
  if index(['system', 'user', 'assistant', 'tool', 'think', 'reasoning'], role) < 0
    echoerr 'akari: invalid history role: ' .. role
    return
  endif
  if role == 'assistant' && trim(content) == ''
    return
  endif
  var lines = getbufline(buf, 1, '$')
  if len(lines) == 1 && lines[0] == ''
    lines = []
  endif
  SealPending(lines)
  AddMarker(lines, role)
  extend(lines, EncodeContent(content, metadata || role != 'assistant'))
  if !SetBufferLines(buf, lines)
    echoerr 'akari: failed to append history'
    return
  endif
  if buf == bufnr()
    cursor(line('$'), 1)
  endif
enddef

export def AppendMessage(message: dict<any>, buf: number): void
  var role: string = message.role
  var content: string
  var has_metadata = false
  if role == 'tool' || role == 'reasoning'
    var item = copy(message)
    remove(item, 'role')
    content = json_encode(item)
  else
    content = message.content
    if role == 'assistant'
      if trim(content) == ''
        return
      endif
      AssistantContent(message)
      var metadata: dict<any> = {}
      for field in ['id', 'phase', 'status']
        if has_key(message, field)
          metadata[field] = message[field]
        endif
      endfor
      if has_key(message, 'content_parts')
        metadata.content = message.content_parts
      endif
      has_metadata = !empty(metadata)
      if has_metadata
        content = json_encode(metadata) .. "\n" .. content
      endif
    endif
  endif
  Append(role, content, buf, has_metadata)
enddef

export def RestoreResponse(buf: number, lines: list<string>): void
  EndStream(buf)
  if !SetBufferLines(buf, lines)
    throw 'akari: failed to restore response history'
  endif
enddef

export def AppendStreamChunk(role: string, content: string, buf: number): void
  if content == ''
    return
  endif
  if !bufexists(buf) || getbufvar(buf, '&filetype') != 'akari'
    echoerr 'akari: no history buffer'
    return
  endif
  if index(['assistant', 'think'], role) < 0
    echoerr 'akari: invalid streamed role: ' .. role
    return
  endif
  var key = string(buf)
  var marker = '<<< ' .. role
  var stream: dict<any> = get(streaming, key, {})
  var marker_line = get(stream, 'marker_line', 0)
  var continuing = get(stream, 'role', '') == role && marker_line > 0
    && getbufline(buf, marker_line) == [marker]
    && getbufinfo(buf)[0].linecount == get(stream, 'tail_line', 0)
    && getbufline(buf, stream.tail_line) == [stream.encoded_tail]
  if !continuing
    var lines = getbufline(buf, 1, '$')
    if len(lines) == 1 && lines[0] == ''
      lines = []
    endif
    var original = copy(lines)
    SealPending(lines)
    AddMarker(lines, role)
    add(lines, '')
    # Only the pending input can need escaping; leave the old history untouched.
    var start = len(original)
    for index in range(len(original))
      if original[index] != lines[index]
        start = index
        break
      endif
    endfor
    if start < len(original) && setbufline(buf, start + 1, lines[start : len(original) - 1]) != 0
      echoerr 'akari: failed to seal user input'
      return
    endif
    if empty(original)
      if setbufline(buf, 1, lines) != 0
        echoerr 'akari: failed to start streamed history'
        return
      endif
    elseif appendbufline(buf, len(original), lines[len(original) :]) != 0
      echoerr 'akari: failed to start streamed history'
      return
    endif
    marker_line = len(lines) - 1
    stream = {role: role, marker_line: marker_line, tail_line: len(lines), tail: '', encoded_tail: ''}
  endif

  var text = stream.tail .. content
  var raw = split(text, "\n", true)
  var encoded = EncodeContent(text, role != 'assistant' || stream.tail_line != marker_line + 1)
  if setbufline(buf, stream.tail_line, encoded[0]) != 0
      || (len(encoded) > 1 && appendbufline(buf, stream.tail_line, encoded[1 :]) != 0)
    echoerr 'akari: failed to update streamed history'
    if has_key(streaming, key)
      remove(streaming, key)
    endif
    return
  endif
  stream.tail_line += len(raw) - 1
  stream.tail = raw[-1]
  stream.encoded_tail = encoded[-1]
  streaming[key] = stream
  if buf == bufnr()
    cursor(line('$'), 1)
    redraw
  endif
enddef

export def EndStream(buf: number): void
  var key = string(buf)
  if has_key(streaming, key)
    remove(streaming, key)
  endif
enddef

export def StartInput(buf: number): void
  if !bufexists(buf) || getbufvar(buf, '&filetype') != 'akari'
    echoerr 'akari: no history buffer'
    return
  endif
  EndStream(buf)
  var lines = getbufline(buf, 1, '$')
  if PendingStart(lines) > 0
    if buf == bufnr()
      cursor(line('$'), 1)
    endif
    return
  endif
  if len(lines) == 1 && lines[0] == ''
    lines = []
  endif
  AddMarker(lines, 'user')
  add(lines, '')
  if !SetBufferLines(buf, lines)
    echoerr 'akari: failed to start user input'
    return
  endif
  if buf == bufnr()
    cursor(line('$'), 1)
  endif
enddef
