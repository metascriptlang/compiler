" MetaScript basic syntax highlighting (fallback for non-Tree-sitter users)
if exists("b:current_syntax")
  finish
endif

syntax keyword msKeyword class interface function const let var return if else for while new extends implements type import export default macro extern defer distinct unreachable match try catch typeof enum break continue switch of in as from throw test out move async await yield
syntax keyword msType string number boolean void any unknown never int8 int16 int32 int64 uint8 uint16 uint32 uint64 float32 float64 int float double Uint8Array Int8Array Uint16Array Int16Array Uint32Array Int32Array Float32Array Float64Array bigint
syntax keyword msBoolean true false
syntax keyword msConstant null undefined

syntax match msComment "//.*$"
syntax region msComment start="/\*" end="\*/"
syntax region msString start=+"+ skip=+\\"+ end=+"+
syntax region msString start=+'+ skip=+\\'+ end=+'+
syntax region msString start=+`+ skip=+\\`+ end=+`+

syntax match msNumber "\<\d\+\>"
syntax match msNumber "\<0x[0-9a-fA-F]+\>"

highlight default link msKeyword Keyword
highlight default link msType Type
highlight default link msBoolean Boolean
highlight default link msConstant Constant
highlight default link msComment Comment
highlight default link msString String
highlight default link msNumber Number

let b:current_syntax = "metascript"
