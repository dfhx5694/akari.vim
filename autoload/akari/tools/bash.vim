vim9script

import autoload 'akari/utils/buffer.vim' as Buffer

var active_tasks: dict<any> = {}

def ReadOutput(task: dict<any>): string
  return filereadable(task.file) ? join(readfile(task.file, 'b'), "\n") : ''
enddef

def EnsureState(session_state: dict<any>): void
  if !has_key(session_state, 'jobs')
    session_state.jobs = {}
    session_state.next_id = 0
  endif
enddef

def Result(task: dict<any>): dict<any>
  return {
    ok: task.status == 'running' || (task.status == 'done' && task.code == 0),
    output: task.output,
    job_id: task.id,
    status: task.status,
    code: task.code,
    timed_out: task.timed_out,
    cancelled: task.status == 'stopped',
  }
enddef

def CleanupFile(task: dict<any>): void
  if delete(task.file) == 0 || getftype(task.file) == ''
    if has_key(active_tasks, task.file)
      remove(active_tasks, task.file)
    endif
  endif
enddef

def FinishJob(task: dict<any>, code: number): void
  if task.finished
    return
  endif
  task.finished = true
  if task.timer != -1
    timer_stop(task.timer)
    task.timer = -1
  endif
  task.code = code
  if task.status == 'running'
    task.status = 'done'
  endif
  try
    task.output = ReadOutput(task)
  catch
    task.output = 'failed to read command output: ' .. v:exception
    if task.status == 'done'
      task.code = -1
    endif
  finally
    CleanupFile(task)
  endtry
  var OnDone = task.OnDone
  task.OnDone = null
  if OnDone != null
    call(OnDone, [Result(task)])
  endif
enddef

def StopTask(task: dict<any>, status: string): void
  if task.finished || task.status != 'running'
    return
  endif
  task.status = status
  task.timed_out = status == 'timed_out'
  if task.timer != -1
    timer_stop(task.timer)
    task.timer = -1
  endif
  # File output is complete when exit_cb runs; no channel close callback is needed.
  if job_status(task.job) == 'run'
    job_stop(task.job, 'kill')
  else
    FinishJob(task, get(job_info(task.job), 'exitval', -1))
  endif
enddef

def StartCommand(input: dict<any>, session_state: dict<any>, OnDone: any): dict<any>
  if !has('job') || !has('timers')
    return {ok: false, output: 'this Vim build requires job and timer support'}
  endif
  var cwd = getcwd()
  var path: string = get(input, 'path', '')
  if path != ''
    cwd = Buffer.Path(path)
  endif
  if !isdirectory(cwd)
    return {ok: false, output: 'directory not found: ' .. cwd}
  endif

  EnsureState(session_state)
  session_state.next_id += 1
  var id = string(session_state.next_id)
  var task: dict<any> = {
    id: id,
    file: tempname(),
    job: null,
    timer: -1,
    status: 'running',
    code: -1,
    output: '',
    timed_out: false,
    finished: false,
    OnDone: get(input, 'async', false) ? null : OnDone,
  }
  session_state.jobs[id] = task
  active_tasks[task.file] = task
  try
    task.job = job_start([&shell, &shellcmdflag, input.command], {
      cwd: cwd,
      in_io: 'null',
      out_io: 'file',
      out_name: task.file,
      err_io: 'out',
      exit_cb: (_: job, code: number) => FinishJob(task, code),
    })
    if job_status(task.job) == 'fail'
      throw 'job_start failed'
    endif
    var timeout: number = get(input, 'timeout', 0)
    if timeout > 0 && !task.finished
      task.timer = timer_start(timeout, (_: number) => StopTask(task, 'timed_out'))
    endif
  catch
    var error = v:exception
    # Suppress the exit callback before reporting a startup failure.
    task.finished = true
    task.OnDone = null
    if task.job != null && job_status(task.job) == 'run'
      job_stop(task.job, 'kill')
    endif
    CleanupFile(task)
    remove(session_state.jobs, id)
    return {ok: false, output: 'failed to start command: ' .. error}
  endtry
  return {ok: true, output: 'started bash job ' .. id, job_id: id, status: 'running'}
enddef

def GetResult(input: dict<any>, session_state: dict<any>): dict<any>
  var id: string = input.job_id
  if !has_key(session_state, 'jobs') || !has_key(session_state.jobs, id)
    return {ok: false, output: 'unknown bash job: ' .. id}
  endif
  var task = session_state.jobs[id]
  if !task.finished
    try
      task.output = ReadOutput(task)
    catch
      return {ok: false, output: 'failed to read command output: ' .. v:exception}
    endtry
  endif
  return Result(task)
enddef

export def Run(input: dict<any>, session_state: dict<any>, OnDone: any): void
  for key in ['mode', 'command', 'path', 'job_id']
    if has_key(input, key) && type(input[key]) != v:t_string
      call(OnDone, [{ok: false, output: key .. ' must be a string'}])
      return
    endif
  endfor
  if has_key(input, 'async') && type(input.async) != v:t_bool
    call(OnDone, [{ok: false, output: 'async must be a boolean'}])
    return
  endif
  if has_key(input, 'timeout')
    if type(input.timeout) != v:t_number || input.timeout < 0
      call(OnDone, [{ok: false, output: 'timeout must be a non-negative integer in milliseconds'}])
      return
    endif
  endif
  var mode: string = get(input, 'mode', 'run')
  if mode == 'get'
    if get(input, 'job_id', '') == ''
      call(OnDone, [{ok: false, output: 'job_id is required'}])
      return
    endif
    call(OnDone, [GetResult(input, session_state)])
    return
  elseif mode != 'run'
    call(OnDone, [{ok: false, output: 'unknown bash mode: ' .. mode}])
    return
  endif
  if get(input, 'command', '') == ''
    call(OnDone, [{ok: false, output: 'command is required'}])
    return
  endif
  var result = StartCommand(input, session_state, OnDone)
  if !result.ok || get(input, 'async', false)
    call(OnDone, [result])
  endif
enddef

export def Stop(session_state: dict<any>): void
  if !has_key(session_state, 'jobs')
    return
  endif
  for task in values(session_state.jobs)
    StopTask(task, 'stopped')
  endfor
enddef

def CleanupOnLeave(): void
  for task in values(copy(active_tasks))
    StopTask(task, 'stopped')
    FinishJob(task, -1)
    CleanupFile(task)
  endfor
enddef

augroup akari_bash_jobs
  autocmd!
  autocmd VimLeavePre * CleanupOnLeave()
augroup END

export def GetTool(): dict<any>
  return {
    name: 'bash',
    description: 'Run a shell command in the current working directory. By default async=false delivers one result on completion without blocking the editor, making it suitable for compilation; no extra sleep is needed. Set async=true to immediately receive a job_id, then use mode=get to query output and status. stdout and stderr are merged.',
    schema: {
      type: 'object',
      properties: {
        mode: {type: 'string', description: 'run (default) to execute a command, or get to retrieve a job.'},
        command: {type: 'string', description: 'Shell command to execute in run mode; not needed in get mode.'},
        path: {type: 'string', description: 'Working directory for run mode; defaults to the current working directory.'},
        job_id: {type: 'string', description: 'Job id returned by an asynchronous run, required in get mode.'},
        async: {type: 'boolean', description: 'Defaults to false: deliver one result on completion without blocking Vim. If true, immediately return a job_id for mode=get.'},
        timeout: {type: 'integer', minimum: 0, description: 'Maximum command runtime in integer milliseconds for both async values; zero means no timeout.'},
      },
      required: [],
    },
    execute_async: Run,
    stop: Stop,
  }
enddef
