vim9script

import autoload 'akari/config.vim' as config
import autoload 'akari/tools/bash.vim' as Bash
import autoload 'akari/tools/edit.vim' as Edit
import autoload 'akari/tools/read.vim' as Read
import autoload 'akari/tools/write.vim' as Write

var tools: dict<any> = {}
var sources: dict<any> = {}
var session_states: dict<any> = {}

export def Register(source: string, definitions: list<dict<any>>): void
  if source == '' || empty(definitions)
    echoerr 'akari: invalid tool registration'
    return
  endif
  if has_key(sources, source)
    echoerr 'akari: tool source already registered: ' .. source
    return
  endif

  var registered: list<dict<any>> = []
  var names: dict<bool> = {}
  for definition in definitions
    var name = get(definition, 'name', '')
    var execute = get(definition, 'execute', null)
    var execute_async = get(definition, 'execute_async', null)
    var stop = get(definition, 'stop', null)
    var description = get(definition, 'description', '')
    var schema = get(definition, 'schema', {type: 'object', properties: {}})
    if type(name) != v:t_string || name == ''
        || (type(execute) != v:t_func && type(execute_async) != v:t_func)
        || (execute != null && type(execute) != v:t_func)
        || (execute_async != null && type(execute_async) != v:t_func)
        || (stop != null && type(stop) != v:t_func)
        || type(description) != v:t_string || type(schema) != v:t_dict
      echoerr 'akari: invalid tool registration: ' .. source
      return
    endif
    if has_key(names, name) || has_key(tools, name)
      echoerr 'akari: duplicate tool: ' .. name
      return
    endif
    names[name] = true
    var tool = copy(definition)
    tool.source = source
    tool.description = description
    tool.schema = schema
    tool.stop = stop
    add(registered, tool)
  endfor

  for tool in registered
    tools[tool.name] = tool
  endfor
  sources[source] = {names: keys(names)}
enddef

export def Definitions(): list<dict<any>>
  var definitions: list<dict<any>> = []
  for tool in values(tools)
    add(definitions, {
      name: tool.name,
      description: tool.description,
      schema: tool.schema,
      source: tool.source,
    })
  endfor
  return definitions
enddef

def NormalizeResult(name: string, result: any): dict<any>
  if type(result) != v:t_dict
    return {ok: false, output: 'tool ' .. name .. ' returned an invalid result'}
  endif
  var ok: any = get(result, 'ok', false)
  if type(ok) != v:t_bool
    return {ok: false, output: 'tool ' .. name .. ' returned an invalid result status'}
  endif
  var output: any = get(result, 'output', '')
  result.output = type(output) == v:t_string ? output : json_encode(output)
  return result
enddef

export def Execute(name: string, input: dict<any>, buf: number, OnDone: func): void
  var completion = {done: false}
  var Done = (result: any) => {
    if !completion.done
      completion.done = true
      call(OnDone, [NormalizeResult(name, result)])
    endif
  }
  if !has_key(tools, name)
    Done({ok: false, output: 'unknown tool: ' .. name})
    return
  endif
  var tool = tools[name]
  var allowed = config.Options().always_allow_tools
  if index(allowed, name) < 0
    var prompt = 'akari: ' .. name .. "\n" .. json_encode(input)
    if confirm(prompt, "&Yes\n&No") != 1
      Done({ok: false, output: 'user denied tool access', denied: true})
      return
    endif
  endif
  var key = string(buf)
  if !has_key(session_states, key)
    session_states[key] = {}
  endif
  if !has_key(session_states[key], name)
    session_states[key][name] = {}
  endif
  try
    if has_key(tool, 'execute_async')
      call(tool.execute_async, [input, session_states[key][name], Done])
    else
      Done(call(tool.execute, [input, session_states[key][name]]))
    endif
  catch
    if completion.done
      throw v:exception
    endif
    Done({ok: false, output: 'tool ' .. name .. ' error: ' .. v:exception})
  endtry
enddef

def StopSession(key: string): void
  if !has_key(session_states, key)
    return
  endif
  for [name, tool] in items(tools)
    var stop = tool.stop
    if stop == null || !has_key(session_states[key], name)
      continue
    endif
    try
      call(stop, [session_states[key][name]])
    catch
      echomsg 'akari: stop failed for tool ' .. name .. ': ' .. v:exception
    endtry
  endfor
enddef

export def StopAll(buf: number = -1): void
  if buf > 0
    StopSession(string(buf))
    return
  endif
  for key in keys(session_states)
    StopSession(key)
  endfor
enddef

def CleanupSession(buf: number): void
  var key = string(buf)
  StopSession(key)
  if has_key(session_states, key)
    remove(session_states, key)
  endif
enddef

export def ShowTools(): void
  var allowed = config.Options().always_allow_tools
  var source_names = sort(keys(sources))
  for source in source_names
    echomsg source .. ':'
    var names: list<string> = copy(sources[source].names)
    sort(names)
    for name in names
      var tool = tools[name]
      var suffix = index(allowed, name) >= 0 ? ' [always allow]' : ''
      echomsg '  ' .. name .. ': ' .. tool.description .. suffix
    endfor
  endfor
enddef

Register('akari', [Read.GetTool(), Write.GetTool(), Edit.GetTool(), Bash.GetTool()])

augroup AkariTools
  autocmd!
  autocmd BufWipeout * CleanupSession(str2nr(expand('<abuf>')))
augroup END
