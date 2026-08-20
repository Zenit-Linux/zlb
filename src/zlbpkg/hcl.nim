import std/[strutils, tables]
import ./types

type
  TokKind = enum
    tkIdent, tkString, tkNumber, tkBool
    tkLBrace, tkRBrace, tkLBrack, tkRBrack
    tkEq, tkComma, tkEof

  Token = object
    kind: TokKind
    text: string

proc tokenize(src: string): seq[Token] =
  result = @[]
  var i = 0
  let n = src.len
  while i < n:
    let c = src[i]
    if c in {' ', '\t', '\r', '\n'}:
      inc i
    elif c == '#' or (c == '/' and i+1 < n and src[i+1] == '/'):
      while i < n and src[i] != '\n': inc i
    elif c == '/' and i+1 < n and src[i+1] == '*':
      i += 2
      while i+1 < n and not (src[i] == '*' and src[i+1] == '/'): inc i
      i += 2
    elif c == '"':
      var j = i + 1
      var s = ""
      while j < n and src[j] != '"':
        if src[j] == '\\' and j+1 < n:
          let nx = src[j+1]
          case nx
          of 'n': s.add '\n'
          of 't': s.add '\t'
          of '"': s.add '"'
          of '\\': s.add '\\'
          else: s.add nx
          j += 2
        else:
          s.add src[j]
          inc j
      result.add Token(kind: tkString, text: s)
      i = j + 1
    elif c == '{':
      result.add Token(kind: tkLBrace, text: "{"); inc i
    elif c == '}':
      result.add Token(kind: tkRBrace, text: "}"); inc i
    elif c == '[':
      result.add Token(kind: tkLBrack, text: "["); inc i
    elif c == ']':
      result.add Token(kind: tkRBrack, text: "]"); inc i
    elif c == '=':
      result.add Token(kind: tkEq, text: "="); inc i
    elif c == ',':
      result.add Token(kind: tkComma, text: ","); inc i
    elif c.isDigit or (c == '-' and i+1 < n and src[i+1].isDigit):
      var j = i
      if src[j] == '-': inc j
      while j < n and (src[j].isDigit or src[j] == '.'): inc j
      result.add Token(kind: tkNumber, text: src[i..<j])
      i = j
    elif c.isAlphaAscii or c == '_':
      var j = i
      while j < n and (src[j].isAlphaNumeric or src[j] == '_' or src[j] == '-' or src[j] == '.'):
        inc j
      let word = src[i..<j]
      if word == "true" or word == "false":
        result.add Token(kind: tkBool, text: word)
      else:
        result.add Token(kind: tkIdent, text: word)
      i = j
    else:
      # Unknown character: skip it rather than hard-failing, manifests
      # should stay easy to hand-edit.
      inc i
  result.add Token(kind: tkEof, text: "")

type Parser = object
  toks: seq[Token]
  pos: int

proc cur(p: Parser): Token = p.toks[p.pos]
proc advance(p: var Parser): Token =
  result = p.toks[p.pos]
  if p.pos < p.toks.high: inc p.pos

proc expect(p: var Parser, k: TokKind, ctx: string) =
  if p.cur.kind != k:
    raise newException(ZlbError,
      "HCL parse error near '" & p.cur.text & "' while parsing " & ctx)
  discard p.advance()

proc newBlock(): HclValue =
  HclValue(kind: hkBlock, fields: newOrderedTable[string, HclValue]())

proc parseValue(p: var Parser): HclValue

proc parseList(p: var Parser): HclValue =
  result = HclValue(kind: hkList, listVal: @[])
  expect(p, tkLBrack, "list")
  while p.cur.kind != tkRBrack:
    result.listVal.add parseValue(p)
    if p.cur.kind == tkComma: discard p.advance()
  expect(p, tkRBrack, "list")

proc parseValue(p: var Parser): HclValue =
  case p.cur.kind
  of tkString:
    result = HclValue(kind: hkString, strVal: p.cur.text)
    discard p.advance()
  of tkNumber:
    result = HclValue(kind: hkNumber, numVal: parseFloat(p.cur.text))
    discard p.advance()
  of tkBool:
    result = HclValue(kind: hkBool, boolVal: p.cur.text == "true")
    discard p.advance()
  of tkLBrack:
    result = parseList(p)
  else:
    raise newException(ZlbError, "HCL parse error: expected a value near '" & p.cur.text & "'")

proc setField(blk: HclValue, key: string, val: HclValue) =
  ## Repeated keys (e.g. multiple `module` blocks) collapse into a list.
  if blk.fields.hasKey(key):
    let existing = blk.fields[key]
    if existing.kind == hkList and existing.listVal.len > 0 and existing.listVal[0].kind == hkBlock:
      existing.listVal.add val
    else:
      var merged = HclValue(kind: hkList, listVal: @[existing, val])
      blk.fields[key] = merged
  else:
    blk.fields[key] = val

proc parseBlockBody(p: var Parser): HclValue =
  result = newBlock()
  while p.cur.kind == tkIdent:
    let name = p.advance().text
    if p.cur.kind == tkString:
      # labeled nested block: name "label" { ... }
      let label = p.advance().text
      expect(p, tkLBrace, "block '" & name & "'")
      var inner = parseBlockBody(p)
      expect(p, tkRBrace, "block '" & name & "'")
      inner.fields["_label"] = HclValue(kind: hkString, strVal: label)
      setField(result, name, inner)
    elif p.cur.kind == tkLBrace:
      discard p.advance()
      var inner = parseBlockBody(p)
      expect(p, tkRBrace, "block '" & name & "'")
      setField(result, name, inner)
    elif p.cur.kind == tkEq:
      discard p.advance()
      let val = parseValue(p)
      setField(result, name, val)
    else:
      raise newException(ZlbError, "HCL parse error: expected '=' or '{' after '" & name & "'")

proc parseHcl*(src: string): HclValue =
  ## Parse an HCL document into a root block value.
  var p = Parser(toks: tokenize(src), pos: 0)
  result = parseBlockBody(p)

# ---- convenience accessors -------------------------------------------------

proc `[]`*(v: HclValue, key: string): HclValue =
  if v.kind != hkBlock or not v.fields.hasKey(key):
    return nil
  v.fields[key]

proc getStr*(v: HclValue, key: string, default = ""): string =
  let f = v[key]
  if f.isNil: return default
  case f.kind
  of hkString: f.strVal
  of hkNumber: $f.numVal
  of hkBool: $f.boolVal
  else: default

proc getBool*(v: HclValue, key: string, default = false): bool =
  let f = v[key]
  if f.isNil or f.kind != hkBool: return default
  f.boolVal

proc getStrList*(v: HclValue, key: string): seq[string] =
  result = @[]
  let f = v[key]
  if f.isNil: return
  if f.kind == hkList:
    for item in f.listVal:
      if item.kind == hkString: result.add item.strVal
  elif f.kind == hkString:
    result.add f.strVal

proc getBlock*(v: HclValue, key: string): HclValue =
  v[key]

proc label*(v: HclValue): string =
  if v.isNil: return ""
  v.getStr("_label")
