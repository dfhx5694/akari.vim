vim9script

import autoload 'akari/config.vim'

import autoload 'akari/provider.vim'
import autoload 'akari/history.vim'
import autoload 'akari/tool.vim'

var states: dict<any> = {}

def Arguments(raw: string): any
	var value: any
	try
		value = json_decode(raw)
	catch
		return null
	endtry
	return type(value) == v:t_dict ? value : null
enddef

def ReportError(message: string): void
	echohl ErrorMsg
	echomsg 'akari: ' .. message
	echohl None
enddef

def ToolRequest(call: dict<any>): dict<any>
	return {tool: call.function.name, id: call.id, arguments: call.function.arguments}
enddef

def RecordToolResult(buf: number, state: dict<any>, request: dict<any>, result: dict<any>): void
	var normalized = extend(copy(result), {tool: request.tool, id: request.id}, 'force')
	history.Append('tool', json_encode(normalized), buf)
	var message: dict<any> = {role: 'tool'}
	extend(message, normalized)
	add(state.messages, message)
enddef

def RecordCancelledRequests(buf: number, state: dict<any>, requests: list<dict<any>>, start: number): void
	var index = start
	while index < len(requests)
		RecordToolResult(buf, state, requests[index], {
			ok: false,
			output: 'tool call cancelled before execution',
			cancelled: true,
			status: 'cancelled',
		})
		index += 1
	endwhile
enddef

def SetFoldMethod(buf: number, method: string): void
	for winid in win_findbuf(buf)
		setwinvar(winid, '&foldmethod', method)
	endfor
enddef

def FinishSession(buf: number): void
	history.EndStream(buf)
	var key = string(buf)
	if has_key(states, key)
		remove(states, key)
		SetFoldMethod(buf, 'syntax')
	endif
enddef

def FailSession(buf: number, message: string): void
	FinishSession(buf)
	ReportError(message)
enddef

def RunSession(buf: number, state: dict<any>, response: any, has_response: bool = false): void
	if !bufexists(buf)
		FinishSession(buf)
		return
	endif
	if has_response && state.stream && (state.model.type == 'responses'
		|| state.stopped || get(response, 'cancelled', false) || get(response, 'error', '') != '')
		history.RestoreResponse(buf, state.response_lines)
	endif
	if state.stopped
		FinishSession(buf)
		return
	endif

	if !has_response
		state.response_lines = getbufline(buf, 1, '$')
		var request_options: dict<any> = {stream: state.stream, buf: buf}
		if state.stream
			request_options.on_chunk = (role: string, content: string) => {
				if !state.stopped && bufexists(buf)
					history.AppendStreamChunk(role, content, buf)
				endif
			}
		endif
		try
			provider.Chat(state.model, state.messages, state.tools, request_options,
				(result: any) => RunSession(buf, state, result, true))
		catch
			FailSession(buf, 'failed to start chat request: ' .. v:exception)
		endtry
		return
	endif

	history.EndStream(buf)
	if get(response, 'cancelled', false)
		FinishSession(buf)
		return
	endif
	var response_error: string = get(response, 'error', '')
	if response_error != ''
		FailSession(buf, response_error)
		return
	endif
	var message: dict<any> = response.choices[0].message
	var content: string = message.content
	var reasoning: string = message.reasoning_content
	var structured = has_key(message, 'history')
	if structured

		for item in message.history
			history.AppendMessage(item, buf)
			add(state.messages, item)
		endfor
	elseif reasoning != ''
		if !state.stream
			history.Append('think', reasoning, buf)
		endif
		add(state.messages, {role: 'think', content: reasoning})
	endif
	if !structured && content != ''
		if !state.stream
			history.Append('assistant', content, buf)
		endif
		add(state.messages, {role: 'assistant', content: content})
	endif

	if has_key(response, 'incomplete')
		history.StartInput(buf)
		FinishSession(buf)
		ReportError('response incomplete: ' .. response.incomplete)
		return
	endif

	var calls: list<dict<any>> = message.tool_calls
	if empty(calls)
		history.StartInput(buf)
		FinishSession(buf)
		return
	endif

	var requests: list<dict<any>> = []
	for call in calls
		if state.stopped
			FinishSession(buf)
			return
		endif
		add(requests, ToolRequest(call))
	endfor

	if !structured
		for request in requests
			history.Append('tool', json_encode(request), buf)
			add(state.messages, {
				role: 'tool',
				tool: request.tool,
				id: request.id,
				arguments: request.arguments,
			})
		endfor
	endif

	ExecuteRequests(buf, state, requests, 0)
enddef

def ExecuteRequests(buf: number, state: dict<any>, requests: list<dict<any>>, request_index: number): void
	if !bufexists(buf)
		FinishSession(buf)
		return
	endif
	if state.stopped
		RecordCancelledRequests(buf, state, requests, request_index)
		FinishSession(buf)
		return
	endif
	if request_index >= len(requests)
		RunSession(buf, state, v:null)
		return
	endif
	var request = requests[request_index]
	var Done = (result: dict<any>) => {
		if !bufexists(buf)
			FinishSession(buf)
			return
		endif
		RecordToolResult(buf, state, request, result)
		timer_start(0, (_) => ExecuteRequests(buf, state, requests, request_index + 1))
	}
	var arguments = Arguments(request.arguments)
	if type(arguments) != v:t_dict
		Done({ok: false, output: 'invalid tool arguments: expected a JSON object; correct the arguments and try again'})
	else
		tool.Execute(request.tool, arguments, buf, Done)
	endif
enddef

export def Ask(): void
	var buf = history.TargetBuffer()
	var key = string(buf)
	if states->has_key(key)
		echoerr 'akari: session is already running in this buffer'
		return
	endif

	var messages = history.Messages(buf)
	if empty(messages) || messages[-1].role != 'user'
		echoerr 'akari: no user input in history'
		return
	endif
	var options = config.Options()
	var selected_model = config.Model(options.default_model)
	var state: dict<any> = {
		stopped: false,
		messages: messages,
		model: selected_model,
		tools: tool.Definitions(),
		stream: options.stream,
	}
	states[key] = state
	SetFoldMethod(buf, 'manual')
	RunSession(buf, state, v:null)
enddef

export def Stop(): void
	var buf = history.TargetBuffer()
	var key = string(buf)
	if !has_key(states, key)
		return
	endif
	states[key].stopped = true
	provider.Stop(buf)
	tool.StopAll(buf)
	echo 'akari: stopped'
enddef

export def StopBuffer(buf: number): void
	var key = string(buf)
	if !has_key(states, key)
		return
	endif
	states[key].stopped = true
	provider.Stop(buf)
	tool.StopAll(buf)
	FinishSession(buf)
enddef

export def SelectModel(): void
	var options = config.Options()
	var names = config.ModelNames()
	if names->empty()
		echoerr 'akari: no models configured'
		return
	endif
	var selected: number = inputlist(['Select model:'] + names->mapnew((i, n) => printf('%d. %s', i + 1, n)))
	if selected >= 1 && selected <= len(names)
		options.default_model = names[selected - 1]
		g:akari_options = options
	endif
enddef

augroup AkariLLM
	autocmd!
	autocmd BufWipeout * StopBuffer(str2nr(expand('<abuf>')))
augroup END
