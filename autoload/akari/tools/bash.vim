vim9script

import autoload 'akari/utils/buffer.vim' as Buffer

var active_tasks: dict<any> = {}
var jobs: dict<any> = {}
var next_id: number = 0

def ReadOutput(task: dict<any>): string
  return filereadable(task.file) ? join(readfile(task.file, 'b'), "\n") : ''
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

# OnDone is called on completion when non-null. Pass null to only get the start result.
def StartCommand(input: dict<any>, OnDone: any): dict<any>
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

  next_id += 1
  var id = string(next_id)
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
    OnDone: OnDone,
  }
  jobs[id] = task
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
    remove(jobs, id)
    return {ok: false, output: 'failed to start command: ' .. error}
  endtry
  return {ok: true, output: 'started command job ' .. id, job_id: id, status: 'running'}
enddef

def ValidateInput(input: dict<any>): string
  for key in ['command', 'path']
    if has_key(input, key) && type(input[key]) != v:t_string
      return key .. ' must be a string'
    endif
  endfor
  if has_key(input, 'timeout')
    if type(input.timeout) != v:t_number || input.timeout < 0
      return 'timeout must be a non-negative integer in milliseconds'
    endif
  endif
  if get(input, 'command', '') == ''
    return 'command is required'
  endif
  return ''
enddef

# run_command: run and wait for the result, delivered via OnDone.
export def RunSync(input: dict<any>, session_state: dict<any>, OnDone: any): void
  var err = ValidateInput(input)
  if err != ''
    call(OnDone, [{ok: false, output: err}])
    return
  endif
  var result = StartCommand(input, OnDone)
  if !result.ok
    call(OnDone, [result])
  endif
enddef

# start_command: return a job_id immediately.
export def RunAsync(input: dict<any>, session_state: dict<any>, OnDone: any): void
  var err = ValidateInput(input)
  if err != ''
    call(OnDone, [{ok: false, output: err}])
    return
  endif
  call(OnDone, [StartCommand(input, null)])
enddef

# get_command_result: query a job started by start_command.
export def GetJob(input: dict<any>, session_state: dict<any>): dict<any>
  var raw = get(input, 'job_id', '')
  if type(raw) != v:t_string || raw == ''
    return {ok: false, output: 'job_id is required'}
  endif
  var id: string = raw
  if !has_key(jobs, id)
    return {ok: false, output: 'unknown command job: ' .. id}
  endif
  var task = jobs[id]
  if !task.finished
    try
      task.output = ReadOutput(task)
    catch
      return {ok: false, output: 'failed to read command output: ' .. v:exception}
    endtry
  endif
  return Result(task)
enddef

# Shared by all command jobs; called when the akari session is stopped.
export def Stop(session_state: dict<any>): void
  for task in values(jobs)
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

augroup akari_command_jobs
  autocmd!
  autocmd VimLeavePre * CleanupOnLeave()
augroup END

export def GetTool(): dict<any>
  return {
    name: 'run_command',
    description: 'Run a shell command in the current working directory and wait for it to finish, then deliver the full output and exit code. Does not block the editor. stdout and stderr are merged.',
    schema: {
      type: 'object',
      properties: {
        command: {type: 'string', description: 'Shell command to execute.'},
        path: {type: 'string', description: 'Working directory; defaults to the current working directory.'},
        timeout: {type: 'integer', minimum: 0, description: 'Maximum runtime in integer milliseconds; zero means no timeout.'},
      },
      required: ['command'],
    },
    execute_async: RunSync,
    stop: Stop,
  }
enddef

export def GetStartTool(): dict<any>
  return {
    name: 'start_command',
    description: 'Start a shell command in the current working directory without waiting for it. Returns a job_id immediately; use get_command_result with that job_id to check status and read output. stdout and stderr are merged.',
    schema: {
      type: 'object',
      properties: {
        command: {type: 'string', description: 'Shell command to execute.'},
        path: {type: 'string', description: 'Working directory; defaults to the current working directory.'},
        timeout: {type: 'integer', minimum: 0, description: 'Maximum runtime in integer milliseconds; zero means no timeout.'},
      },
      required: ['command'],
    },
    execute_async: RunAsync,
    stop: Stop,
  }
enddef

export def GetJobTool(): dict<any>
  return {
    name: 'get_command_result',
    description: 'Query a command job started by start_command. Returns its current status and output so far, or the final result if it has finished.',
    schema: {
      type: 'object',
      properties: {
        job_id: {type: 'string', description: 'Job id returned by start_command.'},
      },
      required: ['job_id'],
    },
    execute: GetJob,
  }
enddef
