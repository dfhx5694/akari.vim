vim9script

import autoload 'akari/config.vim'
import autoload 'akari/history.vim' as historylib
import autoload 'akari/utils/http.vim'
import autoload 'akari/utils/sse.vim'
import autoload 'akari/utils/messages.vim' as messagelib

var continuations: dict<any> = {}

export def Forget(buf: number): void
  var key = string(buf)
  if has_key(continuations, key)
    remove(continuations, key)
  endif
enddef

def RequireString(value: any, field: string, nonempty: bool = false): string
  if type(value) != v:t_string || (nonempty && value == '')
    throw field .. ' must be a ' .. (nonempty ? 'non-empty ' : '') .. 'string'
  endif
  return value
enddef

def SerializeMessages(messages: list<dict<any>>): list<dict<any>>
  var output: list<dict<any>> = []
  for message in messages
    var role = get(message, 'role', 'user')
    if role == 'think'
      continue
    elseif role == 'reasoning'
      var item = copy(message)
      remove(item, 'role')
      add(output, item)
    elseif role == 'tool'
      var id = RequireString(get(message, 'id', null), 'tool call id', true)
      if has_key(message, 'arguments')
        var arguments = message.arguments
        if type(arguments) != v:t_string && type(arguments) != v:t_dict
          throw 'tool call arguments must be a string or object'
        endif
        add(output, {
          type: 'function_call', call_id: id,
          name: RequireString(get(message, 'tool', null), 'tool name', true),
          arguments: type(arguments) == v:t_string ? arguments : json_encode(arguments),
        })
      else
        var result = copy(message)
        remove(result, 'role')
        add(output, {type: 'function_call_output', call_id: id, output: json_encode(result)})
      endif
    else
      var item: dict<any> = {
        role: role,
        content: RequireString(get(message, 'content', ''), 'message content'),
      }
      if role == 'assistant'
        if trim(item.content) == ''
          continue
        endif
        item.type = 'message'
        item.status = RequireString(get(message, 'status', 'completed'), 'assistant status', true)
        item.content = historylib.AssistantContent(message)
        for part in item.content
          if part.type == 'output_text'
            part.annotations = []
          endif
        endfor
        for field in ['id', 'phase']
          if has_key(message, field)
            item[field] = message[field]
          endif
        endfor
      endif
      add(output, item)
    endif
  endfor
  return output
enddef

def BuildTools(tools: list<dict<any>>): list<dict<any>>
  var output: list<dict<any>> = []
  for tool in tools
    add(output, {
      type: 'function', name: tool.name, description: tool.description,
      parameters: tool.schema, strict: false,
    })
  endfor
  return output
enddef

def BuildPayload(model: dict<any>, messages: list<dict<any>>, tools: list<dict<any>>, stream: bool): string
  for field in ['conversation', 'previous_response_id']
    if has_key(model, field)
      throw 'manual ' .. field .. ' is not supported: history is managed locally; remove this model setting (store: true enables automatic previous_response_id)'
    endif
  endfor
  var background = get(model, 'background', false)
  if type(background) != v:t_bool
    throw 'background must be a boolean'
  endif
  if background
    throw 'background is not supported: remove background or set it to false; Responses requires a terminal response'
  endif
  var payload: dict<any> = {}
  var internal = ['type', 'endpoint', 'api_key', 'timeout', 'model', 'input', 'stream', 'tools']
  for [key, value] in items(model)
    if index(internal, key) < 0
      payload[key] = value
    endif
  endfor
  payload.model = model.model
  messagelib.ValidateTools(messages)
  payload.input = SerializeMessages(messages)
  payload.stream = stream
  if !empty(tools)
    payload.tools = BuildTools(tools)
  endif
  return json_encode(payload)
enddef

def NormalizeResponse(response: any): dict<any>
  if type(response) != v:t_dict
    throw 'response must be a JSON object'
  endif
  if get(response, 'error', null) != null
    throw 'provider returned an error: ' .. json_encode(response.error)
  endif
  var status = get(response, 'status', '')
  var incomplete = status == 'incomplete'
  if status != 'completed' && !incomplete
    throw 'response is not completed: ' .. json_encode({
      status: get(response, 'status', null),
      incomplete_details: get(response, 'incomplete_details', null),
    })
  endif
  var output = get(response, 'output', null)
  if type(output) != v:t_list
    throw 'response output must be a list'
  endif
  var history: list<dict<any>> = []
  var calls: list<dict<any>> = []
  var call_ids: dict<bool> = {}
  var content = ''
  var reasoning = ''
  for item in output
    if type(item) != v:t_dict
      throw 'response output item must be an object'
    endif
    var kind = RequireString(get(item, 'type', null), 'output item type', true)
    if kind == 'reasoning'
      RequireString(get(item, 'id', null), 'reasoning id', true)
      var summary = get(item, 'summary', null)
      if type(summary) != v:t_list
        throw 'reasoning summary must be a list'
      endif
      for part in summary
        if type(part) != v:t_dict || get(part, 'type', '') != 'summary_text'
          throw 'reasoning summary item must be a summary_text object'
        endif
        reasoning ..= RequireString(get(part, 'text', null), 'reasoning summary text')
      endfor
      if has_key(item, 'encrypted_content') && item.encrypted_content != null
        RequireString(item.encrypted_content, 'reasoning encrypted_content')
      endif
      add(history, extend(copy(item), {role: 'reasoning'}, 'force'))
    elseif kind == 'message'
      if get(item, 'role', '') != 'assistant' || type(get(item, 'content', null)) != v:t_list
        throw 'response message must have assistant role and a content list'
      endif
      var text = ''
      var descriptors: list<dict<any>> = []
      for part in item.content
        if type(part) != v:t_dict
          throw 'response message content item must be an object'
        endif
        var value: string
        if get(part, 'type', '') == 'output_text'
          value = RequireString(get(part, 'text', null), 'output text')
        elseif get(part, 'type', '') == 'refusal'
          value = RequireString(get(part, 'refusal', null), 'refusal text')
        else
          throw 'unsupported response message content type: ' .. string(get(part, 'type', null))
        endif
        text ..= value
        add(descriptors, {type: part.type, length: strlen(value)})
      endfor
      var message: dict<any> = {
        role: 'assistant', content: text,
        status: RequireString(get(item, 'status', status), 'assistant status', true),
      }
      if len(descriptors) != 1 || descriptors[0].type != 'output_text'
        message.content_parts = descriptors
      endif
      if has_key(item, 'id')
        message.id = RequireString(item.id, 'assistant id', true)
      endif
      if has_key(item, 'phase')
        if item.phase != null
          RequireString(item.phase, 'assistant phase')
        endif
        message.phase = item.phase
      endif
      historylib.ValidateAssistantMetadata(message)
      if trim(text) != ''
        add(history, message)
      endif
      content ..= text
    elseif kind == 'function_call'
      var id = RequireString(get(item, 'call_id', null), 'function call call_id', true)
      if has_key(call_ids, id)
        throw 'duplicate function call call_id in response: ' .. id
      endif
      call_ids[id] = true
      if incomplete
        continue
      endif
      if has_key(item, 'status') && item.status != 'completed'
        throw 'function call ' .. id .. ' is not completed: ' .. string(item.status)
      endif
      var name = RequireString(get(item, 'name', null), 'function call name', true)
      var arguments = RequireString(get(item, 'arguments', null), 'function call arguments')
      add(history, {role: 'tool', tool: name, id: id, arguments: arguments})
      add(calls, {id: id, type: 'function', function: {name: name, arguments: arguments}})
    else
      throw 'unsupported response output type: ' .. kind
    endif
  endfor
  var message: dict<any> = {
    content: content, reasoning_content: reasoning, tool_calls: calls, history: history,
  }
  var normalized: dict<any> = {
    choices: [{message: message}], id: get(response, 'id', ''), store: get(response, 'store', false),
  }
  if incomplete
    var details = get(response, 'incomplete_details', null)
    normalized.incomplete = type(details) == v:t_dict
      ? RequireString(get(details, 'reason', 'unknown'), 'incomplete reason', true) : 'unknown'
  endif
  return normalized
enddef

def ProcessStreamEvent(event: dict<any>, state: dict<any>, OnChunk: any): void
  var payload = RequireString(get(event, 'data', null), 'stream event data')
  if payload == '' || payload == '[DONE]'
    return
  endif
  var object = json_decode(payload)
  if type(object) != v:t_dict
    throw 'stream event must be a JSON object'
  endif
  var kind = RequireString(get(object, 'type', get(event, 'event', '')), 'stream event type', true)
  if kind == 'error' || kind == 'response.failed'
    state.error = 'provider returned ' .. kind .. ': ' .. json_encode(object)
  elseif kind == 'response.completed' || kind == 'response.incomplete'
    if state.response != null
      throw 'stream contains multiple terminal responses'
    endif
    # Only terminal output is authoritative; tool argument deltas are not accumulated.
    state.response = NormalizeResponse(get(object, 'response', null))
  elseif kind == 'response.output_text.delta' || kind == 'response.refusal.delta'
      || kind == 'response.reasoning_summary_text.delta'
    var delta = RequireString(get(object, 'delta', null), 'stream delta')
    if delta != '' && OnChunk != null
      call(OnChunk, [kind == 'response.reasoning_summary_text.delta' ? 'think' : 'assistant', delta])
    endif
  endif
enddef

def HandleStreamEvent(event: dict<any>, state: dict<any>, OnChunk: any): void
  try
    ProcessStreamEvent(event, state, OnChunk)
  catch
    if state.parse_error == ''
      state.parse_error = v:exception
    endif
  endtry
enddef

def FinishResponse(result: dict<any>, state: dict<any>, stream: bool, OnDone: any): void
  if get(result, 'cancelled', false)
    call(OnDone, [{choices: [], cancelled: true}])
    return
  endif
  if get(result, 'error', '') != ''
    call(OnDone, [{choices: [], error: result.error}])
    return
  endif
  if stream
    sse.Finish(state.sse)
  endif
  if state.parse_error != '' || state.error != ''
    call(OnDone, [{choices: [], error: 'akari: invalid responses stream: ' ..
      (state.parse_error != '' ? state.parse_error : state.error)}])
    return
  endif
  var response: dict<any>
  try
    if stream
      if state.response == null
        throw 'stream ended without a response.completed or response.incomplete event'
      endif
      response = state.response
    else
      response = NormalizeResponse(json_decode(get(result, 'body', '')))
    endif
  catch
    call(OnDone, [{choices: [], error: 'akari: invalid responses response: ' .. v:exception}])
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
    event: 'chat_request', model: model.model, stream: stream,
    messages: len(messages), tools: len(tools), payload_bytes: strlen(body),
    api_key_configured: key != '',
  }
  try
    writefile([json_encode(entry)], log_file, 'a')
  catch
  endtry
enddef

def PreparePayload(buf: number, model: dict<any>, messages: list<dict<any>>, tools: list<dict<any>>, stream: bool): dict<any>
  var payload = json_decode(BuildPayload(model, messages, tools, stream))
  var input = deepcopy(payload.input)
  var enabled = type(get(model, 'store', null)) == v:t_bool && get(model, 'store', false)
  var previous: dict<any> = get(continuations, string(buf), {})
  if enabled && !empty(previous) && previous.model == model && previous.tools == tools
    var count = len(previous.input)
    if len(messages) >= len(previous.messages)
            && messages[: len(previous.messages) - 1] == previous.messages
      payload.previous_response_id = previous.id
      payload.input = input[count :]
    else
      Forget(buf)
    endif
  else
    Forget(buf)
  endif
  return {body: json_encode(payload), input: input, messages: deepcopy(messages), enabled: enabled}
enddef

def RememberResponse(buf: number, model: dict<any>, tools: list<dict<any>>, request: dict<any>, response: dict<any>, OnDone: any): void
  Forget(buf)
  var id = get(response, 'id', '')
  if request.enabled && type(get(response, 'store', null)) == v:t_bool && get(response, 'store', false)
      && type(id) == v:t_string && id != '' && !has_key(response, 'error')
      && !get(response, 'cancelled', false) && !has_key(response, 'incomplete')
    continuations[string(buf)] = {
      id: id, model: deepcopy(model), tools: deepcopy(tools),
      input: request.input + SerializeMessages(response.choices[0].message.history),
            messages: request.messages + deepcopy(response.choices[0].message.history),
    }
  endif
  call(OnDone, [response])
enddef

export def Chat(model: dict<any>, messages: list<dict<any>>, tools: list<dict<any>>, options: dict<any>, OnDone: any): void
  var stream: bool = get(options, 'stream', false)
  var buf: number = get(options, 'buf', bufnr())
  try
    var request = PreparePayload(buf, model, messages, tools, stream)
    var body: string = request.body
    var Done = (response: dict<any>) => RememberResponse(buf, model, tools, request, response, OnDone)
    LogRequest(model, body, stream, messages, tools)
    var state: dict<any> = {response: null, parse_error: '', error: ''}
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
    var url = substitute(model.endpoint, '/\+$', '', '') .. '/responses'
    http.Request(url, body, request_options,
      (result: dict<any>) => FinishResponse(result, state, stream, Done))
  catch
    Forget(buf)
    call(OnDone, [{choices: [], error: 'akari: failed to prepare responses request: ' .. v:exception}])
  endtry
enddef

export def Stop(buf: number): void
  Forget(buf)
  http.Stop(buf)
enddef

augroup AkariResponses
  autocmd!
  autocmd BufUnload * Forget(str2nr(expand('<abuf>')))
augroup END
