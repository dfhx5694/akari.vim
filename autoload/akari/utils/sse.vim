vim9script

export def New(OnEvent: any): dict<any>
  return {pending: '', at_start: true, skip_lf: false, event: '', data: [], on_event: OnEvent}
enddef

def ProcessLine(state: dict<any>, line: string): void
  if line == ''
    var data: list<string> = state.data
    var event: string = state.event == '' ? 'message' : state.event
    state.event = ''
    state.data = []
    if !empty(data)
      call(state.on_event, [{event: event, data: join(data, "\n")}])
    endif
    return
  endif
  if line[0] == ':'
    return
  endif
  var colon = stridx(line, ':')
  var field = colon < 0 ? line : strpart(line, 0, colon)
  var value = colon < 0 ? '' : strpart(line, colon + 1)
  if strpart(value, 0, 1) == ' '
    value = strpart(value, 1)
  endif
  if field == 'data'
    add(state.data, value)
  elseif field == 'event'
    state.event = value
  endif
enddef

export def Feed(state: dict<any>, chunk: string): void
  state.pending ..= chunk
  if state.at_start
    var bom = "\xef\xbb\xbf"
    var length = strlen(state.pending)
    if length < 3 && state.pending == strpart(bom, 0, length)
      return
    endif
    state.at_start = false
    if strpart(state.pending, 0, 3) == bom
      state.pending = strpart(state.pending, 3)
    endif
  endif
  while state.pending != ''
    if state.skip_lf
      state.skip_lf = false
      if strpart(state.pending, 0, 1) == "\n"
        state.pending = strpart(state.pending, 1)
      endif
    endif
    var newline = match(state.pending, '[\r\n]')
    if newline < 0
      break
    endif
    var line = strpart(state.pending, 0, newline)
    state.skip_lf = strpart(state.pending, newline, 1) == "\r"
    state.pending = strpart(state.pending, newline + 1)
    ProcessLine(state, line)
  endwhile
enddef

export def Finish(state: dict<any>): void
  # SSE dispatches only on a blank line; discard an incomplete final event.
  state.pending = ''
  state.at_start = false
  state.skip_lf = false
  state.event = ''
  state.data = []
enddef
