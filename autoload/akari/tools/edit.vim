vim9script

import autoload 'akari/utils/buffer.vim' as Buffer
import autoload 'akari/utils/text.vim' as Text

def CountMatches(haystack: string, needle: string): number

  var count = 0
  var pos = 0
  while true
    var index = stridx(haystack, needle, pos)
    if index < 0
      break
    endif
    count += 1
    pos = index + 1
  endwhile
  return count
enddef

def TrimIndent(value: string): string
  return substitute(value, '^\s*', '', '')
enddef

def FirstIndent(lines: list<string>): string
  for line in lines
    if line =~ '\S'
      return matchstr(line, '^\s*')
    endif
  endfor
  return ''
enddef

def ShiftIndent(line: string, delta: number, use_tabs: bool): string
  if line =~ '^\s*$'
    return ''
  endif
  var indent = matchstr(line, '^\s*')
  var body = strpart(line, strlen(indent))
  var width = max([0, strdisplaywidth(indent) + delta])
  var adjusted = repeat(' ', width)
  if use_tabs
    var tabstop = max([1, &tabstop])
    adjusted = repeat('\t', width / tabstop) .. repeat(' ', width % tabstop)
  endif
  return adjusted .. body
enddef

def ShiftReplacement(lines: list<string>, delta: number, use_tabs: bool): list<string>
  var shifted: list<string> = []
  for line in lines
    add(shifted, ShiftIndent(line, delta, use_tabs))
  endfor
  return shifted
enddef


def TrimEscapes(value: string): string
  return substitute(substitute(substitute(substitute(value, '\\n', "\n", 'g'), '\\r', "\r", 'g'), '\\t', "\t", 'g'), '\\\\', '\\', 'g')
enddef

def TrimSuffixWhitespace(value: string): string
  return substitute(value, '[ \t]\+$', '', '')
enddef

def FindMatch(original: list<string>, target: list<string>, Compare: func): list<number>
  if empty(target) || len(target) > len(original)
    return [0, 0]
  endif
  var start = 0
  while start <= len(original) - len(target)
    var matched = true
    var offset = 0
    while offset < len(target)
      if !Compare(original[start + offset], target[offset])
        matched = false
        break
      endif
      offset += 1
    endwhile
    if matched
      return [start + 1, start + len(target)]
    endif
    start += 1
  endwhile
  return [0, 0]
enddef

def FuzzyMatch(original: list<string>, target: list<string>): list<number>
  var result = FindMatch(original, target, (a: string, b: string): bool => a == b)
  if result[0] != 0
    return result
  endif
  result = FindMatch(original, target, (a: string, b: string): bool => TrimSuffixWhitespace(a) == TrimSuffixWhitespace(b))
  if result[0] != 0
    return result
  endif
  result = FindMatch(original, target, (a: string, b: string): bool => TrimIndent(a) == TrimIndent(b))
  if result[0] != 0
    return result
  endif
  result = FindMatch(original, target, (a: string, b: string): bool => a == TrimEscapes(b))
  if result[0] != 0
    return result
  endif
  return FindMatch(original, target, (a: string, b: string): bool => TrimIndent(a) == TrimIndent(TrimEscapes(b)))
enddef

export def Run(input: dict<any>, session_state: dict<any>): dict<any>
  for key in ['path', 'search', 'replace']
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
  var search: string = input.search
  var replace: string = input.replace
  if search == ''
    return {ok: false, output: 'search is empty'}
  endif
  var abs = Buffer.Path(rel)
  var buf = Buffer.Find(abs)
  if buf <= 0 && !filereadable(abs)
    return {ok: false, output: 'file not found: ' .. abs}
  endif
  if buf > 0 && !getbufvar(buf, '&modifiable')
    return {ok: false, output: 'buffer is not modifiable: ' .. abs}
  endif

  search = Text.NormalizeNewlines(search)
  replace = Text.NormalizeNewlines(replace)
  if search == replace
    return {ok: false, output: 'search and replace are identical'}
  endif


  var contents = ''
  var original: list<string> = []
  if buf > 0
    original = Buffer.Lines(buf)
    contents = join(original, "\n")
  else
    contents = Text.ReadDisk(abs)
    original = split(contents, "\n", true)
  endif
  var count = CountMatches(contents, search)
  var updated = ''
  var fuzzy = ''
  if count == 1
    var index = stridx(contents, search)
    updated = strpart(contents, 0, index) .. replace .. strpart(contents, index + strlen(search))
  elseif count > 1
    return {ok: false, output: printf('search matched %d locations in %s; provide more surrounding context', count, rel)}
  else
    var old_lines = split(search, "\n", true)
    var new_lines = split(replace, "\n", true)
    var match = FuzzyMatch(original, old_lines)
    if match[0] == 0
      return {ok: false, output: 'search string not found in ' .. rel .. '; read the file and retry with exact text'}
    endif
    var remaining = match[0] < len(original) ? original[match[0] :] : []
    var second = FuzzyMatch(remaining, old_lines)
    if second[0] != 0
      return {ok: false, output: 'search is non-unique in ' .. rel .. '; add more context'}
    endif
    var start_line = match[0]
    var end_line = match[1]
    var original_indent = FirstIndent(original[start_line - 1 : end_line - 1])
    var replacement_indent = FirstIndent(new_lines)
    var delta = strdisplaywidth(original_indent) - strdisplaywidth(replacement_indent)
    var use_tabs = original_indent =~ '\t' && original_indent !~ ' '
    if delta != 0
      new_lines = ShiftReplacement(new_lines, delta, use_tabs)
      fuzzy = 'indentation'
    else
      fuzzy = 'whitespace'
    endif
    var before = start_line > 1 ? original[: start_line - 2] : []
    var after = end_line < len(original) ? original[end_line :] : []
    updated = join(before + new_lines + after, "\n")
  endif
  if buf > 0
    if !Buffer.ReplaceText(buf, updated)
      return {ok: false, output: 'failed to update buffer: ' .. abs}
    endif
    try
      Buffer.Save(buf)
    catch
      return {ok: false, output: 'buffer updated but save failed: ' .. v:exception, source: 'buffer'}
    endtry
    return {ok: true, output: 'edited and saved buffer ' .. abs, fuzzy: fuzzy, source: 'buffer'}
  endif
  try
    if !Text.WriteDisk(abs, updated)
      return {ok: false, output: 'write failed: ' .. abs}
    endif
  catch
    return {ok: false, output: 'write failed: ' .. v:exception}
  endtry
  return {ok: true, output: 'edited file ' .. abs, fuzzy: fuzzy, source: 'file'}
enddef

export def GetTool(): dict<any>
  return {
    name: 'edit',
    description: 'Replace one unique text occurrence. If a loaded buffer exists for the path, edit and automatically save that buffer; otherwise edit the file. Read the target first and include enough surrounding context for an unambiguous match.',
    schema: {
      type: 'object',
      properties: {
        path: {type: 'string', description: 'File or buffer path, relative to the current working directory or absolute.'},
        search: {type: 'string', description: 'Text to replace. Include surrounding lines when needed to make the match unique; whitespace and indentation differences may be tolerated.'},
        replace: {type: 'string', description: 'Replacement text. Use newline characters for multi-line replacements.'},
      },
      required: ['path', 'search', 'replace'],
    },
    execute: Run,
  }
enddef
