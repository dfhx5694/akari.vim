vim9script

if exists("b:did_ftplugin")
	finish
endif
b:did_ftplugin = 1

setlocal foldmethod=syntax
setlocal foldlevel=0
setlocal noundofile