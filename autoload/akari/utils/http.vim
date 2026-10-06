vim9script

var active_jobs: dict<any> = {}
var requests: list<dict<any>> = []
var leaving = false
const STATUS_TAIL_LENGTH = strlen('AKARI_HTTP_STATUS:000')

def BuildArguments(url: string, body_file: string, options: dict<any>): list<string>
  var timeout: number = options.timeout
  var args: list<string> = [
    'curl',
    '--config',
    '-',
    '-sS',
    '--fail-with-body',
    '--max-time',
    printf('%.3f', timeout / 1000.0),
    '-X',
    'POST',
    url,
    '-w',
    'AKARI_HTTP_STATUS:%{http_code}',
  ]
  if get(options, 'stream', false)
    add(args, '--no-buffer')
  endif

  add(args, '--data-binary')
  add(args, '@' .. body_file)
  return args
enddef

def HeaderConfig(headers: list<string>): string
  var lines: list<string> = []
  for header in headers
    var value = escape(header, '\"')
    value = substitute(value, "\n", '\\n', 'g')
    value = substitute(value, "\r", '\\r', 'g')
    value = substitute(value, "\t", '\\t', 'g')
    value = substitute(value, nr2char(11), '\\v', 'g')
    add(lines, 'header = "' .. value .. '"')
  endfor
  return join(lines, "\n") .. "\n"
enddef

def Cleanup(state: dict<any>): void
  var body_file: string = state.body_file
  state.body_file = ''
  if body_file != ''
    try
      delete(body_file)
    catch
    endtry
  endif
  if get(active_jobs, state.key, {}) is state
    remove(active_jobs, state.key)
  endif
  var index = indexof(requests, (_, request) => request is state)
  if index >= 0
    remove(requests, index)
  endif
enddef

def Output(state: dict<any>, data: string): void
  if state.done || state.cancelled || leaving
    return
  endif
  state.body ..= data
  if state.on_data == null
    return
  endif
  var pending: string = state.stream_tail .. data
  var length = strlen(pending) - STATUS_TAIL_LENGTH
  if length > 0
    state.stream_tail = strpart(pending, length)
    call(state.on_data, [strpart(pending, 0, length)])
  else
    state.stream_tail = pending
  endif
enddef

def FinishRequest(state: dict<any>): void
  if state.done || !state.exited || !state.closed
    return
  endif
  state.done = true
  Cleanup(state)
  if leaving
    return
  endif
  if state.cancelled
    call(state.on_done, [{cancelled: true}])
    return
  endif
  if state.start_error != ''
    call(state.on_done, [{error: state.start_error}])
    return
  endif

  var exit_code: number = state.exit_code
  var status_text = matchstr(trim(state.body), 'AKARI_HTTP_STATUS:\zs\d\{3}$')
  var status = status_text == '' ? 0 : str2nr(status_text)
  var body = substitute(state.body, 'AKARI_HTTP_STATUS:\d\{3}$', '', '')
  var error = ''
  if exit_code != 0 || status >= 400
    var details = filter([trim(body), trim(state.error)], (_, text) => text != '')
    error = printf('curl failed (HTTP %d, exit %d): %s', status, exit_code, join(details, "\n"))
  elseif state.error != ''
    error = 'akari: ' .. state.error
  endif
  # Strip only curl's writeout, preserving SSE's terminating blank line.
  var tail = substitute(state.stream_tail, 'AKARI_HTTP_STATUS:\d\{3}$', '', '')
  state.stream_tail = ''
  if state.on_data != null && tail != ''
    call(state.on_data, [tail])
  endif
  call(state.on_done, [{body: body, status: status, error: error}])
enddef

def Exited(state: dict<any>, exit_code: number): void
  state.exited = true
  state.exit_code = exit_code
  FinishRequest(state)
enddef

def Closed(state: dict<any>): void
  # close_cb runs after both output callbacks have drained their channels.
  state.closed = true
  FinishRequest(state)
enddef

def Kill(state: dict<any>): void
  if state.job != null
    try
      job_stop(state.job, 'kill')
    catch
    endtry
  endif
enddef

export def Request(url: string, body: string, options: dict<any>, OnDone: any): void
  if leaving
    return
  endif
  var header_config = HeaderConfig(get(options, 'headers', []))
  var body_file = tempname()
  var args = BuildArguments(url, body_file, options)
  var state: dict<any> = {
    key: string(options.buf), job: null, body: '', body_file: body_file,
    error: '', start_error: '', done: false, cancelled: false,
    exited: false, closed: false, exit_code: -1, on_done: OnDone,
    on_data: get(options, 'on_data', null), stream_tail: '',
  }
  # Register before job_start/job_status: either can invoke callbacks.
  active_jobs[state.key] = state
  add(requests, state)
  try
    if writefile(split(body, "\n", true), body_file, 'b') != 0
      throw 'failed to write curl request body'
    endif
    state.job = job_start(args, {
      in_mode: 'raw',
      out_mode: 'raw',
      err_mode: 'raw',
      out_cb: (_channel: channel, data: string) => Output(state, data),
      err_cb: (_channel: channel, data: string) => {
        if !state.done && !state.cancelled && !leaving
          state.error ..= data
        endif
      },
      exit_cb: (_job: job, exit_code: number) => Exited(state, exit_code),
      close_cb: (_channel: channel) => Closed(state),
    })
  catch
    state.start_error = 'akari: failed to start curl job: ' .. v:exception
    state.exited = true
    state.closed = true
    FinishRequest(state)
    return
  endtry
  var status = job_status(state.job)
  if state.done
    if leaving
      Kill(state)
    endif
    return
  endif
  if status == 'fail'
    state.start_error = 'akari: failed to start curl job'
    state.exited = true
    state.closed = true
    FinishRequest(state)
    return
  endif
  if state.cancelled || leaving
    Kill(state)
    return
  endif
  if status != 'run' || state.exited || state.closed
    return
  endif
  var channel = job_getchannel(state.job)
  try
    ch_sendraw(channel, header_config)
    ch_close_in(channel)
  catch
    if !state.done
      state.error = 'failed to send curl configuration: ' .. v:exception
      Kill(state)
    endif
  endtry
enddef

export def Stop(buf: number): void
  var state = get(active_jobs, string(buf), {})
  if empty(state) || state.done || state.cancelled
    return
  endif
  state.cancelled = true
  Kill(state)
enddef

def Leave(): void
  leaving = true
  for state in copy(requests)
    state.cancelled = true
    state.done = true
    Kill(state)
    Cleanup(state)
  endfor
enddef

augroup akari_http_cleanup
  autocmd!
  autocmd VimLeavePre * Leave()
augroup END
