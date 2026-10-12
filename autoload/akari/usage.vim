vim9script

import autoload 'akari/history.vim'

export def Get(buf: number = 0): string
  return history.UsageJSON(buf)
enddef
