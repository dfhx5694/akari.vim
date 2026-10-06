vim9script

import autoload 'akari/utils/text.vim' as Text

export def Path(path: string): string
  return fnamemodify(expand(path), ':p')
enddef

def CanonicalPath(path: string): string
  var absolute = resolve(Path(path))
  return has('win32') || has('win64') ? tolower(absolute) : absolute
enddef

export def Find(path: string): number
  var target = CanonicalPath(path)
  for info in getbufinfo({'bufloaded': 1})
    if info.name != '' && CanonicalPath(info.name) == target
      return info.bufnr
    endif
  endfor
  return -1
enddef

export def Lines(buf: number): list<string>
  return getbufline(buf, 1, '$')
enddef

export def ReplaceText(buf: number, text: string, final_eol: any = null): bool
  if !bufloaded(buf) || !getbufvar(buf, '&modifiable')
    return false
  endif
  var normalized_text = Text.NormalizeNewlines(text)
  var lines = split(normalized_text, "\n", true)
  if final_eol != null && final_eol && len(lines) > 1 && lines[-1] == ''
    remove(lines, -1)
  endif
  var old_count = len(getbufline(buf, 1, '$'))
  if setbufline(buf, 1, lines) != 0
    return false
  endif
  if old_count > len(lines) && deletebufline(buf, len(lines) + 1, old_count) != 0
    return false
  endif
  if final_eol != null
    setbufvar(buf, '&endofline', final_eol)
  endif
  return true
enddef
