# akari.vim

`akari.vim` is a Vim plugin that supports the Chat Completions and Responses APIs. It includes a basic tool-calling loop and an extensible interface for adding tools.

## Installation

To install the plugin using Vim's native package support, clone it into an optional package directory:

```sh
git clone https://github.com/dfhx5694/akari.vim ~/.vim/pack/plugins/opt/akari.vim
```

Then add the following line to your `~/.vimrc` to load it:

```vim
packadd akari.vim
```

Alternatively, install and manage the plugin with a Vim plugin manager such as dein.vim, Pathogen, vim-plug, Volt, or Vundle.

## Configuration

See `:help akari-configuration` for configuration options.

## Commands

| Command | Description |
| --- | --- |
| `:AkariNew` | Start a conversation. |
| `:AkariAsk` | Send the text in the `>>> user` section. |
| `:AkariStop` | Stop the current request or tool. |
| `:AkariModel` | Switch the default model. |
| `:AkariTools` | List available tools and their permissions. |
