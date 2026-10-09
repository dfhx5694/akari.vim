# akari.vim

Plain-text conversations. Local tools. No web UI, no ceremony.

```text
>>> user
Build this project and fix any errors.
```

`:AkariAsk` sends it. The assistant can read, edit and write files, or run a build while Vim stays responsive.

## Install

Requires Vim 9.0+ with Vim9script, jobs, channels and timers; and curl 7.76+.

Clone into Vim's `pack/*/start` directory, or add this repository to `'runtimepath'`:

```sh
git clone https://github.com/dfhx5694/akari.vim ~/.vim/pack/plugins/start/akari.vim
```

Windows: use `$HOME/vimfiles/pack/plugins/start/akari.vim`.

## Configure

See [`config.example`](config.example) for configuration.

## Commands

| Command | Action |
| --- | --- |
| `:AkariNew` | Start a conversation |
| `:AkariAsk` | Send the text under `>>> user` |
| `:AkariStop` | Stop the current request or tool |
| `:AkariModel` | Switch the default model |
| `:AkariTools` | List available tools and permissions |

Conversations are editable `.akari` files. Tools can access local files and run shell commands; requests require confirmation unless their names are in `always_allow_tools`.

## Add a tool

Register tools with `akari#tool#Register(source, definitions)`:

```vim
function! Greet(input, state) abort
  return {'ok': v:true, 'output': 'Hello, ' .. a:input.name}
endfunction

call akari#tool#Register('my-plugin', [{
      \ 'name': 'greet',
      \ 'description': 'Greet someone by name.',
      \ 'schema': {
      \   'type': 'object',
      \   'properties': {'name': {'type': 'string'}},
      \   'required': ['name'],
      \ },
      \ 'execute': function('Greet'),
      \ }])
```

`execute(input, state)` returns `{'ok': bool, 'output': string}`. The per-buffer `state` dictionary lives for the conversation session. Asynchronous tools can use `execute_async(input, state, callback)`; long-running tools should provide a `stop(state)` callback.
