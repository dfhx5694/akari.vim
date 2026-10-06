vim9script

export def NormalizeNewlines(text: string): string
  return substitute(substitute(text, "\r\n", "\n", 'g'), "\r", "\n", 'g')
enddef

export def ReadDisk(path: string): string
  return NormalizeNewlines(join(readfile(path, 'b'), "\n"))
enddef

export def WriteDisk(path: string, content: string): bool
  var normalized = NormalizeNewlines(content)
  return writefile(split(normalized, "\n", true), path, 'b') == 0
enddef
