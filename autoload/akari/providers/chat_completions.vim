vim9script

import autoload 'akari/config.vim'

import autoload 'akari/utils/http.vim'
import autoload 'akari/utils/sse.vim'
import autoload 'akari/utils/messages.vim' as messagelib

def SerializeToolResult(message: dict<any>): string
  var result = copy(message)
  remove(result, 'role')
  return json_encode(result)
enddef

def SerializeMessages(messages: list<dict<any>>): list<dict<any>>
  messagelib.ValidateTools(messages)
  var output: list<dict<any>> = []
  var pending_calls: list<dict<any>> = []

  def FlushCalls(): void
    if empty(pending_calls)
      return
    endif
    var assistant: dict<any> = {
      role: 'assistant',
      content: v:null,
      tool_calls: pending_calls,
    }
    if !empty(output) && get(output[-1], 'role', '') == 'assistant' && !has_key(output[-1], 'tool_calls')
      assistant = extend(copy(remove(output, -1)), {tool_calls: pending_calls}, 'force')
    endif
    add(output, assistant)
    pending_calls = []
  enddef

  for message in messages
    var role = get(message, 'role', 'user')
    if role == 'reasoning'
      continue
    endif
    var plain = role == 'assistant' ? {role: role, content: message.content} : message
    if role == 'tool'
      if has_key(message, 'arguments')
        var arguments = get(message, 'arguments', {})
        var argument_text = type(arguments) == v:t_string ? arguments : json_encode(arguments)
        add(pending_calls, {
          id: get(message, 'id', ''),
          type: 'function',
          function: {
            name: get(message, 'tool', ''),
            arguments: argument_text,
          },
        })
        continue
      endif
      FlushCalls()
      var content = get(message, 'content', '')
      if has_key(message, 'ok') || has_key(message, 'output')
        content = SerializeToolResult(message)
      elseif type(content) != v:t_string
        content = json_encode(content)
      endif
      add(output, {
        role: 'tool',
        tool_call_id: get(message, 'id', get(message, 'tool_call_id', '')),
        content: content,
      })
      continue
    endif
    FlushCalls()
    if role == 'think'
      add(output, {role: 'assistant', content: v:null, reasoning_content: message.content})
    elseif role == 'assistant' && !empty(output) && output[-1].role == 'assistant'
        && has_key(output[-1], 'reasoning_content') && output[-1].content == v:null
        && !has_key(output[-1], 'tool_calls')
      extend(output[-1], plain, 'force')
    elseif role == 'assistant'
      add(output, copy(plain))
    else
      add(output, {role: role, content: get(message, 'content', '')})
    endif
  endfor
  FlushCalls()
  return filter(output, (_, item) => !(item.role == 'assistant'
    && has_key(item, 'reasoning_content') && item.content == v:null
    && !has_key(item, 'tool_calls')))
enddef

def BuildTools(tools: list<dict<any>>): list<dict<any>>
  var output: list<dict<any>> = []
  for tool in tools
    add(output, {
      type: 'function',
      function: {
        name: tool.name,
        description: tool.description,
        parameters: tool.schema,
      },
    })
  endfor
  return output
enddef



def ProcessStreamEvent(event: dict<any>, state: dict<any>, OnChunk: any): void
  var payload: string = event.data
  if payload == ''
    return
  endif
  if payload == '[DONE]'
    if state.done
      throw 'duplicate stream [DONE]'
    endif
    state.done = true
    return
  endif
  var object = json_decode(payload)
  if type(object) != v:t_dict
    throw 'stream event must be a JSON object'
  endif
  if has_key(object, 'error')
    state.error = 'provider returned an error: ' .. json_encode(object.error)
    return
  endif

  var choices = get(object, 'choices', [])
  if type(choices) != v:t_list
    throw 'stream choices must be a list'
  endif
  if empty(choices)
    if type(get(object, 'usage', null)) != v:t_dict
      throw 'empty stream choices require usage'
    endif
    return
  endif
  if state.done || state.finish_reason != ''
    throw 'stream choice received after termination'
  endif
  if len(choices) != 1 || type(choices[0]) != v:t_dict
    throw 'stream must contain exactly one choice'
  endif
  var choice = choices[0]
  if type(get(choice, 'index', null)) != v:t_number || choice.index != 0
    throw 'stream choice index must be zero (only n=1 is supported)'
  endif
  var finish_reason = get(choice, 'finish_reason', null)
  if finish_reason != null && (type(finish_reason) != v:t_string || finish_reason == '')
    throw 'stream finish_reason must be a non-empty string or null'
  endif
  var delta = get(choice, 'delta', {})
  if type(delta) != v:t_dict
    throw 'stream delta must be an object'
  endif
  if has_key(delta, 'role') && (type(delta.role) != v:t_string || delta.role != 'assistant')
    throw 'stream delta role must be assistant'
  endif
  state.has_choice = true
  var reasoning = get(delta, 'reasoning_content', get(delta, 'reasoning', ''))
  if reasoning == null
    reasoning = ''
  endif
  if type(reasoning) != v:t_string
    throw 'stream reasoning must be a string'
  endif
  if reasoning != ''
    state.reasoning ..= reasoning

    if OnChunk != null
      call(OnChunk, ['think', reasoning])
    endif
  endif
  var content = get(delta, 'content', '')
  if content != null && type(content) != v:t_string
    throw 'stream content must be a string or null'
  endif
  if type(content) == v:t_string && content != ''
    state.content ..= content

    if OnChunk != null
      call(OnChunk, ['assistant', content])
    endif
  endif
  var refusal = get(delta, 'refusal', '')
  if refusal != null && type(refusal) != v:t_string
    throw 'stream refusal must be a string or null'
  endif
  if type(refusal) == v:t_string && refusal != ''
    state.content ..= refusal
    if OnChunk != null
      call(OnChunk, ['assistant', refusal])
    endif
  endif
  var calls = get(delta, 'tool_calls', [])
  if calls == null
    calls = []
  endif
  if type(calls) != v:t_list
    throw 'stream tool_calls must be a list'
  endif
  for call in calls
    if type(call) != v:t_dict
      throw 'stream tool call must be an object'
    endif
    var raw_index = get(call, 'index', null)
    if type(raw_index) != v:t_number || raw_index < 0
      throw 'stream tool call index must be a non-negative number'
    endif
    var index = string(raw_index)
    if !has_key(state.calls, index)
      state.calls[index] = {id: '', name: '', type: ''}
    endif
    if has_key(call, 'type')
      if type(call.type) != v:t_string || call.type != 'function'
        throw 'stream tool call type must be function'
      endif
      state.calls[index].type = call.type
    endif
    if has_key(call, 'id')
      if type(call.id) != v:t_string || call.id == ''
        throw 'stream tool call id must be a non-empty string'
      endif
      if state.calls[index].id != '' && state.calls[index].id != call.id
        throw 'stream tool call id changed for an existing index'
      endif
      for [other_index, other_call] in items(state.calls)
        if other_index != index && other_call.id == call.id
          throw 'stream tool call ids must be unique'
        endif
      endfor
      state.calls[index].id = call.id
    endif
    var function = get(call, 'function', {})
    if type(function) != v:t_dict
      throw 'stream tool call function must be an object'
    endif
    var name = get(function, 'name', '')
    var arguments = get(function, 'arguments', '')
    if type(name) != v:t_string || type(arguments) != v:t_string
      throw 'stream tool call name and arguments must be strings'
    endif
    state.calls[index].name ..= name
    if has_key(function, 'arguments')
      state.calls[index].arguments = get(state.calls[index], 'arguments', '') .. arguments
    endif
  endfor
  if finish_reason != null
    state.finish_reason = finish_reason
  endif
enddef

def ToolCalls(calls: dict<any>): list<dict<any>>
  var output: list<dict<any>> = []
  var indexes = sort(keys(calls), 'n')
  for index in indexes
    var call = calls[index]
    add(output, {
      id: call.id,
      type: call.type,
      function: {
        name: call.name,
        arguments: get(call, 'arguments', null),
      },
    })
  endfor
  return output
enddef

def IncompleteReason(reason: string): string
  return index(['stop', 'tool_calls'], reason) >= 0 ? ''
    : (reason == '' ? 'missing finish_reason' : reason)
enddef

def StreamResponse(state: dict<any>): dict<any>
  var incomplete = IncompleteReason(state.finish_reason)
  if !state.done
    incomplete = incomplete == '' ? 'missing [DONE]' : incomplete .. '; missing [DONE]'
  endif
  var message: dict<any> = {
    role: 'assistant', content: state.content,
    reasoning_content: state.reasoning,
    tool_calls: incomplete == '' ? ToolCalls(state.calls) : [],
  }
  var response: dict<any> = {
    choices: [{index: 0, finish_reason: state.finish_reason == '' ? null : state.finish_reason, message: message}],
  }
  if incomplete != ''
    response.incomplete = incomplete
  endif
  return response
enddef


def HandleStreamEvent(event: dict<any>, state: dict<any>, OnChunk: any): void
  if state.parse_error != '' || state.error != ''
    return
  endif
  try
    ProcessStreamEvent(event, state, OnChunk)
  catch
    if state.parse_error == ''
      state.parse_error = v:exception
    endif
  endtry
enddef

def FinishResponse(result: dict<any>, state: dict<any>, stream: bool, OnChunk: any, OnDone: any): void
  if get(result, 'cancelled', false)
    call(OnDone, [{choices: [], cancelled: true}])
    return
  endif
  if result.error != ''
    call(OnDone, [{choices: [], error: result.error}])
    return
  endif

  if stream
    if (state.sse.pending != '' || !empty(state.sse.data)) && state.parse_error == ''
      state.parse_error = 'stream ended with an incomplete SSE event'
    endif
    sse.Finish(state.sse)
  endif


  if state.parse_error != ''
    call(OnDone, [{choices: [], error: state.parse_error}])
    return
  endif
  if state.error != ''
    call(OnDone, [{choices: [], error: 'akari: ' .. state.error}])
    return
  endif
  var response: dict<any>
  try
    response = NormalizeResponse(stream
      ? StreamResponse(state)
      : json_decode(result.body))
  catch
    call(OnDone, [{choices: [], error: 'akari: invalid chat completions response: ' .. v:exception}])
    return
  endtry
  call(OnDone, [response])
enddef


def LogRequest(model: dict<any>, body: string, stream: bool, messages: list<dict<any>>, tools: list<dict<any>>): void
  var log_value: string = config.Options().log_file
  if log_value == ''
    return
  endif
  var log_file = expand(log_value)
  if log_file == ''
    return
  endif
  var key: string = model.api_key
  var entry = {
    event: 'chat_request',
    model: model.model,
    stream: stream,
    messages: len(messages),
    tools: len(tools),
    payload_bytes: strlen(body),
    api_key_configured: key != '',
  }
  try
    writefile([json_encode(entry)], log_file, 'a')
  catch
  endtry
enddef

def NormalizeResponse(response: any): dict<any>
  if type(response) != v:t_dict
    throw 'response must be a JSON object'
  endif
  if has_key(response, 'error')
    throw 'provider returned an error: ' .. json_encode(response.error)
  endif
  var choices = get(response, 'choices', null)
  if type(choices) != v:t_list || len(choices) != 1
    throw 'response must contain exactly one choice (only n=1 is supported)'
  endif
  for choice in choices
    if type(choice) != v:t_dict || type(get(choice, 'message', null)) != v:t_dict
      throw 'response choice message must be an object'
    endif
    if type(get(choice, 'index', null)) != v:t_number || choice.index != 0
      throw 'response choice index must be zero'
    endif
    var finish_reason = get(choice, 'finish_reason', null)
    if finish_reason != null && (type(finish_reason) != v:t_string || finish_reason == '')
      throw 'response finish_reason must be a non-empty string or null'
    endif
    var incomplete = IncompleteReason(finish_reason == null ? '' : finish_reason)
    if incomplete != '' && !has_key(response, 'incomplete')
      response.incomplete = incomplete
    endif
    var message: dict<any> = choice.message
    if get(message, 'role', '') != 'assistant'
      throw 'response message role must be assistant'
    endif
    for field in ['content', 'reasoning_content']
      var value = get(message, field, field == 'reasoning_content' ? get(message, 'reasoning', null) : null)
      if value == null
        value = ''
      elseif type(value) != v:t_string
        throw 'response message ' .. field .. ' must be a string or null'
      endif
      message[field] = value
    endfor
    var refusal = get(message, 'refusal', null)
    if refusal != null && type(refusal) != v:t_string
      throw 'response message refusal must be a string or null'
    endif
    if type(refusal) == v:t_string
      message.content ..= refusal
    endif
    # Incomplete calls may be truncated: keep text, never expose pending tools.
    if has_key(response, 'incomplete')
      message.tool_calls = []
      continue
    endif
    var calls = get(message, 'tool_calls', null)
    if calls == null
      calls = []
    endif
    if type(calls) != v:t_list
      throw 'response tool_calls must be a list or null'
    endif
    if finish_reason == 'tool_calls' && empty(calls)
      throw 'response finish_reason tool_calls requires tool calls'
    endif
    if finish_reason == 'stop' && !empty(calls)
      throw 'response finish_reason stop must not include tool calls'
    endif
    var ids: dict<bool> = {}
    for call in calls
      if type(call) != v:t_dict
        throw 'response tool call must be an object'
      endif
      if type(get(call, 'type', null)) != v:t_string || call.type != 'function'
        throw 'response tool call type must be function'
      endif
      if has_key(call, 'index') && (type(call.index) != v:t_number || call.index < 0)
        throw 'response tool call index must be a non-negative number'
      endif
      var id = get(call, 'id', null)
      if type(id) != v:t_string || id == ''
        throw 'response tool call id must be a non-empty string'
      endif
      if has_key(ids, id)
        throw 'response tool call ids must be unique'
      endif
      ids[id] = true
      var function = get(call, 'function', null)
      if type(function) != v:t_dict
        throw 'response tool call function must be an object'
      endif
      var name = get(function, 'name', null)
      if type(name) != v:t_string || name == ''
        throw 'response tool call name must be a non-empty string'
      endif
      var arguments = get(function, 'arguments', null)
      if type(arguments) != v:t_string
        throw 'response tool call arguments must be a string'
      endif
    endfor
    message.tool_calls = calls
  endfor
  return response
enddef

def BuildPayload(model: dict<any>, messages: list<dict<any>>, tools: list<dict<any>>, stream: bool): string
  var n = get(model, 'n', 1)
  if type(n) != v:t_number || n != 1
    throw 'chat completions only supports n=1'
  endif
  var payload: dict<any> = {}
  var internal = ['type', 'endpoint', 'api_key', 'timeout', 'model', 'messages', 'stream', 'tools']
  for [key, value] in items(model)
    if index(internal, key) < 0
      payload[key] = value
    endif
  endfor
  payload.model = model.model
  payload.messages = SerializeMessages(messages)
  payload.stream = stream
  if !empty(tools)
    payload.tools = BuildTools(tools)
  endif
  return json_encode(payload)
enddef

export def Chat(model: dict<any>, messages: list<dict<any>>, tools: list<dict<any>>, options: dict<any>, OnDone: any): void
  var stream: bool = get(options, 'stream', false)
  var buf: number = get(options, 'buf', bufnr())
  try
    var body = BuildPayload(model, messages, tools, stream)
    LogRequest(model, body, stream, messages, tools)
    var state: dict<any> = {
      content: '', reasoning: '', calls: {},
      parse_error: '', error: '', has_choice: false,
      finish_reason: '', done: false,
    }
    var OnChunk = get(options, 'on_chunk', null)
    var headers = ['Content-Type: application/json']
    if model.api_key != ''
      add(headers, 'Authorization: Bearer ' .. model.api_key)
    endif
    var request_options: dict<any> = {
      timeout: model.timeout, buf: buf, stream: stream, headers: headers,
    }
    if stream
      state.sse = sse.New((event: dict<any>) => HandleStreamEvent(event, state, OnChunk))
      request_options.on_data = (data: string) => sse.Feed(state.sse, data)
    endif
    var url = substitute(model.endpoint, '/\+$', '', '') .. '/chat/completions'
    http.Request(url, body, request_options,
      (result: dict<any>) => FinishResponse(result, state, stream, OnChunk, OnDone))
  catch
    call(OnDone, [{choices: [], error: 'akari: failed to prepare chat request: ' .. v:exception}])
  endtry
enddef

export def Stop(buf: number): void
  http.Stop(buf)
enddef
