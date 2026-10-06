vim9script

export def ValidateTools(messages: list<dict<any>>): void
  var pending: dict<string> = {}
  var seen: dict<bool> = {}
  var receiving_results = false
  var message_index = 0
  for message in messages
    message_index += 1
    var role = get(message, 'role', '')
    if role != 'tool'
      if !empty(pending) && (receiving_results || index(['think', 'reasoning'], role) < 0)
        throw printf('tool history message %d: missing results for %s', message_index, join(keys(pending), ', '))
      endif
      continue
    endif
    var id = get(message, 'id', null)
    var name = get(message, 'tool', null)
    if type(id) != v:t_string || id == '' || type(name) != v:t_string || name == ''
      throw printf('tool history message %d: id and tool must be non-empty strings', message_index)
    endif
    if has_key(message, 'arguments')
      if receiving_results && !empty(pending)
        throw printf('tool history message %d: new call before previous results are complete', message_index)
      endif
      var arguments = message.arguments
      if type(arguments) != v:t_string && type(arguments) != v:t_dict
        throw printf('tool history message %d: arguments must be a string or object', message_index)
      endif
      if has_key(seen, id)
        throw printf('tool history message %d: duplicate call id %s', message_index, id)
      endif
      seen[id] = true
      pending[id] = name
      receiving_results = false
    else
      if !has_key(pending, id)
        throw printf('tool history message %d: result has no pending call %s', message_index, id)
      endif
      if pending[id] != name
        throw printf('tool history message %d: tool name does not match call %s', message_index, id)
      endif
      remove(pending, id)
      receiving_results = !empty(pending)
    endif
  endfor
  if !empty(pending)
    throw 'tool history: missing results for ' .. join(keys(pending), ', ')
  endif
enddef
