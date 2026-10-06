vim9script noclear

if get(g:, "akari_loaded", false)
	finish
endif

if !executable("curl")
	echoerr "akari: need curl"
	finish
endif

import autoload "akari/history.vim"
import autoload "akari/llm.vim"
import autoload "akari/tool.vim"


g:akari_loaded = true

augroup Akari
  autocmd!
  autocmd BufEnter *.akari g:akari_last_buffer = bufnr()
augroup END

command! -nargs=0 AkariNew history.NewSession()
command! -nargs=0 AkariAsk llm.Ask()
command! -nargs=0 AkariStop llm.Stop()
command! -nargs=0 AkariModel llm.SelectModel()
command! -nargs=0 AkariTools tool.ShowTools()
