if exists("b:current_syntax")
  finish
endif

" Load base markdown syntax so markdown elements (headers, lists, bold, code blocks) render natively
runtime! syntax/markdown.vim
unlet! b:current_syntax

" YAML Frontmatter
syntax region agentfileHeader start=/^---$/ end=/^---$/ contains=agentfileHeaderKey,agentfileHeaderVal,agentfileComment
syntax match agentfileHeaderKey /^---/ contained
syntax match agentfileHeaderKey /^[a-zA-Z0-9_]\+:/ contained
syntax match agentfileComment /#.*$/ contained

" Block markers at column 0 (>>tag, #tag or [tag])
syntax match agentfileSystem /^>>system\>/
syntax match agentfileSystem /^#system\>/
syntax match agentfileSystem /^\[system\]/
syntax match agentfileMe /^>>me\>/
syntax match agentfileMe /^#me\>/
syntax match agentfileMe /^\[me\]/
syntax match agentfileThinkHeader /^>>think\>/
syntax match agentfileThinkHeader /^#think\>/
syntax match agentfileThinkHeader /^\[think\]/
syntax match agentfileAgent /^>>agent\>/
syntax match agentfileAgent /^#agent\>/
syntax match agentfileAgent /^\[agent\]/
syntax match agentfileResult /^>>result\([ _]id=\d\+\)\?\([ _]status=\w\+\)\?/
syntax match agentfileResult /^#result\([ _]id=\d\+\)\?\([ _]status=\w\+\)\?/
syntax match agentfileResult /^\[result\( id=\d\+\)\?\( status=\w\+\)\?\]/

" Result status variants (defined after the generic match so they win)
syntax match agentfileResultOk /^\[result[^]]*status=ok[^]]*\]/
syntax match agentfileResultOk /^>>result\>.*[ _]status=ok\>/
syntax match agentfileResultOk /^#result\>.*[ _]status=ok\>/
syntax match agentfileResultError /^\[result[^]]*status=error[^]]*\]/
syntax match agentfileResultError /^>>result\>.*[ _]status=error\>/
syntax match agentfileResultError /^#result\>.*[ _]status=error\>/
syntax match agentfileResultPending /^\[result[^]]*status=pending[^]]*\]/
syntax match agentfileResultPending /^>>result\>.*[ _]status=pending\>/
syntax match agentfileResultPending /^#result\>.*[ _]status=pending\>/
syntax match agentfileResultRejected /^\[result[^]]*status=rejected[^]]*\]/
syntax match agentfileResultRejected /^>>result\>.*[ _]status=rejected\>/
syntax match agentfileResultRejected /^#result\>.*[ _]status=rejected\>/
syntax match agentfileAsk /^>>ask\>/
syntax match agentfileAsk /^#ask\>/
syntax match agentfileAsk /^\[ask\]/
syntax match agentfileReset /^>>reset\>/
syntax match agentfileReset /^#reset\>/
syntax match agentfileReset /^\[reset\]/
syntax match agentfileError /^>>error\>/
syntax match agentfileError /^#error\>/
syntax match agentfileError /^\[error\]/
syntax match agentfileDone /^>>done\>/
syntax match agentfileDone /^#done\>/
syntax match agentfileDone /^\[done\]/

" Context meter suffix on the latest [me] line
syntax match agentfileContext /(context \d\+\/\d\+[^)]*)/
syntax match agentfileContext /\[context \d\+\/\d\+\]/

" Tool calls: @tool_name(...)
syntax match agentfileToolCall /@[a-zA-Z0-9_]\+\(([^)]*)\)\?/

" Highlights
highlight default link agentfileHeader Comment
highlight default link agentfileHeaderKey Keyword
highlight default link agentfileComment Comment

highlight default link agentfileSystem Statement
highlight default link agentfileMe Title
highlight default link agentfileThinkHeader Comment
highlight default link agentfileAgent Special
highlight default link agentfileResult Type
highlight default link agentfileResultOk DiagnosticOk
highlight default link agentfileResultError DiagnosticError
highlight default link agentfileResultPending DiagnosticWarn
highlight default link agentfileResultRejected Comment
highlight default link agentfileAsk DiagnosticWarn
highlight default link agentfileReset WarningMsg
highlight default link agentfileError DiagnosticError
highlight default link agentfileDone DiagnosticOk
highlight default link agentfileContext DiagnosticInfo
highlight default link agentfileToolCall Function

let b:current_syntax = "agentfile"
