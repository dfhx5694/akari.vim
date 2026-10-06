vim9script

if exists("b:current_syntax")
  finish
endif

syntax match akariTagSystem "^>>> system"
syntax match akariTagUser "^>>> user"
syntax match akariTagThink "^<<< think"
syntax match akariTagReasoning "^<<< reasoning"
syntax match akariTagTool "^<<< tool"
syntax match akariTagAssistant "^<<< assistant"

syntax region akariFoldReasoning start="^<<< reasoning\>" end="\n^\(>>>\|<<<\)\s" fold transparent
syntax region akariFoldThink start="^<<< think\>" end="\n^\(>>>\|<<<\)\s" fold transparent
syntax region akariFoldTool start="^<<< tool\>" end="\n^\(>>>\|<<<\)\s" fold transparent

highlight def link akariTagSystem Comment
highlight def link akariTagUser String
highlight def link akariTagThink Comment
highlight def link akariTagReasoning Comment
highlight def link akariTagTool Comment
highlight def link akariTagAssistant Comment

b:current_syntax = "akari"
