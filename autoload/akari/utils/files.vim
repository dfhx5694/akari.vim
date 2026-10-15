vim9script

export def Files(abs: string, input: dict<any>): list<string>
  var include = get(input, 'include', '*')
  var recursive = get(input, 'recursive', false)
  var suffix = recursive ? '/**/' .. include : '/' .. include
  return glob(abs .. suffix, false, true)
enddef
