vim9script

import autoload 'akari/providers/chat_completions.vim'
import autoload 'akari/providers/responses.vim'

var active_providers: dict<string> = {}

def ForgetProvider(key: string, provider_type: string): void
	if get(active_providers, key, '') == provider_type
		remove(active_providers, key)
	endif
enddef

export def Chat(model: dict<any>, messages: list<dict<any>>, tools: list<dict<any>>, options: dict<any>, OnDone: any): void
	var provider_type: string = model.type
	if index(['chat_completions', 'responses'], provider_type) < 0
		call(OnDone, [{choices: [], error: 'unknown provider: ' .. provider_type}])
		return
	endif

	var buf: number = get(options, 'buf', bufnr())
	var key = string(buf)
	active_providers[key] = provider_type
	var Done = (response: any) => {
		ForgetProvider(key, provider_type)
		call(OnDone, [response])
	}
	if provider_type == 'responses'
		responses.Chat(model, messages, tools, options, Done)
	else
		responses.Forget(buf)
		chat_completions.Chat(model, messages, tools, options, Done)
	endif
enddef

export def Stop(buf: number): void
	var key = string(buf)
	if !has_key(active_providers, key)
		return
	endif

	var provider_type = active_providers[key]
	if provider_type == 'responses'
		responses.Stop(buf)
		return
	elseif provider_type == 'chat_completions'
		chat_completions.Stop(buf)
		return
	endif
	echoerr 'akari: no stop handler for provider: ' .. provider_type
enddef
