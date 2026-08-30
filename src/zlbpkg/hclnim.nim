import std/[strutils, tables]

type
  HclError* = object of CatchableError
    line*: int  ## 0, jeśli nieznana/nie dotyczy (np. błąd spoza parsera)

  HclKind* = enum
    hkString, hkNumber, hkBool, hkList, hkBlock

  HclValue* = ref object
    case kind*: HclKind
    of hkString: strVal*: string
    of hkNumber: numVal*: float
    of hkBool:   boolVal*: bool
    of hkList:   listVal*: seq[HclValue]
    of hkBlock:  fields*: OrderedTable[string, HclValue]

# ---------------------------------------------------------------------------
# Tokenizer -- śledzi numer linii dla czytelnych komunikatów błędów.
# ---------------------------------------------------------------------------

type
  TokKind = enum
    tkIdent, tkString, tkNumber, tkBool
    tkLBrace, tkRBrace, tkLBrack, tkRBrack
    tkEq, tkComma, tkEof

  Token = object
    kind: TokKind
    text: string
    line: int

proc err(line: int, msg: string): ref HclError =
  result = newException(HclError, (if line > 0: "linia " & $line & ": " else: "") & msg)
  result.line = line

proc tokenize(src: string): seq[Token] =
  result = @[]
  var i = 0
  let n = src.len
  var line = 1
  while i < n:
    let c = src[i]
    if c == '\n':
      inc line; inc i
    elif c in {' ', '\t', '\r'}:
      inc i
    elif c == '#' or (c == '/' and i+1 < n and src[i+1] == '/'):
      while i < n and src[i] != '\n': inc i
    elif c == '/' and i+1 < n and src[i+1] == '*':
      i += 2
      while i+1 < n and not (src[i] == '*' and src[i+1] == '/'):
        if src[i] == '\n': inc line
        inc i
      if i+1 >= n:
        raise err(line, "niezamknięty komentarz blokowy '/*' (brak zamykającego '*/')")
      i += 2
    elif c == '"':
      let startLine = line
      var j = i + 1
      var s = ""
      var closed = false
      while j < n:
        if src[j] == '\n':
          break  # string nie może przechodzić przez koniec linii bez escape'a
        if src[j] == '\\' and j+1 < n:
          let nx = src[j+1]
          case nx
          of 'n': s.add '\n'
          of 't': s.add '\t'
          of '"': s.add '"'
          of '\\': s.add '\\'
          else: s.add nx
          j += 2
        elif src[j] == '"':
          closed = true
          break
        else:
          s.add src[j]
          inc j
      if not closed:
        raise err(startLine, "niedomknięty string (brakujący końcowy '\"')")
      result.add Token(kind: tkString, text: s, line: startLine)
      i = j + 1
    elif c == '{':
      result.add Token(kind: tkLBrace, text: "{", line: line); inc i
    elif c == '}':
      result.add Token(kind: tkRBrace, text: "}", line: line); inc i
    elif c == '[':
      result.add Token(kind: tkLBrack, text: "[", line: line); inc i
    elif c == ']':
      result.add Token(kind: tkRBrack, text: "]", line: line); inc i
    elif c == '=':
      result.add Token(kind: tkEq, text: "=", line: line); inc i
    elif c == ',':
      result.add Token(kind: tkComma, text: ",", line: line); inc i
    elif c.isDigit or (c == '-' and i+1 < n and src[i+1].isDigit):
      var j = i
      if src[j] == '-': inc j
      while j < n and (src[j].isDigit or src[j] == '.'): inc j
      result.add Token(kind: tkNumber, text: src[i..<j], line: line)
      i = j
    elif c.isAlphaAscii or c == '_':
      var j = i
      while j < n and (src[j].isAlphaNumeric or src[j] == '_' or src[j] == '-' or src[j] == '.'):
        inc j
      let word = src[i..<j]
      if word == "true" or word == "false":
        result.add Token(kind: tkBool, text: word, line: line)
      else:
        result.add Token(kind: tkIdent, text: word, line: line)
      i = j
    else:
      # Nieznany znak: pomijany, nie fatalny -- manifesty mają zostać
      # łatwe do ręcznej edycji nawet z drobnym błędem interpunkcyjnym
      # w komentarzu spoza `#`/`//`.
      inc i
  result.add Token(kind: tkEof, text: "", line: line)

# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------

type Parser = object
  toks: seq[Token]
  pos: int

proc cur(p: Parser): Token = p.toks[p.pos]
proc advance(p: var Parser): Token =
  result = p.toks[p.pos]
  if p.pos < p.toks.high: inc p.pos

proc expect(p: var Parser, k: TokKind, ctx: string) =
  if p.cur.kind != k:
    raise err(p.cur.line, "oczekiwano innego tokenu w " & ctx & ", napotkano '" & p.cur.text & "'")
  discard p.advance()

proc newBlock(): HclValue =
  HclValue(kind: hkBlock, fields: initOrderedTable[string, HclValue]())

proc parseValue(p: var Parser): HclValue

proc parseList(p: var Parser): HclValue =
  result = HclValue(kind: hkList, listVal: @[])
  expect(p, tkLBrack, "liście")
  while p.cur.kind != tkRBrack:
    if p.cur.kind == tkEof:
      raise err(p.cur.line, "niedomknięta lista (brakujący końcowy ']')")
    result.listVal.add parseValue(p)
    if p.cur.kind == tkComma: discard p.advance()
  expect(p, tkRBrack, "liście")

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
    raise err(p.cur.line, "oczekiwano wartości (string/liczba/true|false/lista), napotkano '" & p.cur.text & "'")

proc setField(blk: HclValue, key: string, val: HclValue) =
  ## Powtórzone klucze (np. wiele bloków `package "x" {}`) kolapsują w
  ## listę -- patrz `getBlocks`/`getBlock` (ten ostatni zwraca pierwszy).
  if blk.fields.hasKey(key):
    let existing = blk.fields[key]
    if existing.kind == hkList and existing.listVal.len > 0 and existing.listVal[0].kind == hkBlock:
      existing.listVal.add val
    elif existing.kind == hkBlock and val.kind == hkBlock:
      blk.fields[key] = HclValue(kind: hkList, listVal: @[existing, val])
    else:
      blk.fields[key] = HclValue(kind: hkList, listVal: @[existing, val])
  else:
    blk.fields[key] = val

proc parseBlockBody(p: var Parser): HclValue =
  result = newBlock()
  while p.cur.kind == tkIdent:
    let name = p.advance().text
    if p.cur.kind == tkString:
      # blok z etykietą: name "label" { ... } (etykieta trafia do
      # syntetycznego pola "_label", patrz `label()`)
      let label = p.advance().text
      expect(p, tkLBrace, "bloku '" & name & "'")
      var inner = parseBlockBody(p)
      expect(p, tkRBrace, "bloku '" & name & "'")
      inner.fields["_label"] = HclValue(kind: hkString, strVal: label)
      setField(result, name, inner)
    elif p.cur.kind == tkLBrace:
      discard p.advance()
      var inner = parseBlockBody(p)
      expect(p, tkRBrace, "bloku '" & name & "'")
      setField(result, name, inner)
    elif p.cur.kind == tkEq:
      discard p.advance()
      let val = parseValue(p)
      setField(result, name, val)
    else:
      raise err(p.cur.line, "oczekiwano '=' albo '{' po '" & name & "'")
  if p.cur.kind notin {tkRBrace, tkEof}:
    raise err(p.cur.line, "nieoczekiwany token '" & p.cur.text & "' (oczekiwano identyfikatora, '}' albo końca pliku)")

proc parseHcl*(src: string): HclValue =
  ## Parsuje cały dokument, zwracając wirtualny blok główny (root) --
  ## jego `fields` to atrybuty/bloki najwyższego poziomu. Rzuca `HclError`
  ## (z numerem linii w `.line` i w treści `.msg`) przy niedomkniętym
  ## bloku/stringu/liście albo nierozpoznanym tokenie.
  var p = Parser(toks: tokenize(src), pos: 0)
  result = parseBlockBody(p)
  if p.cur.kind != tkEof:
    raise err(p.cur.line, "nadmiarowy '}' bez odpowiadającego otwarcia")

# ---------------------------------------------------------------------------
# Akcesory wygodne -- wspólne dla zpm/zlb/installer
# ---------------------------------------------------------------------------

proc `[]`*(v: HclValue, key: string): HclValue =
  if v.isNil or v.kind != hkBlock or not v.fields.hasKey(key):
    return nil
  v.fields[key]

proc getStr*(v: HclValue, key: string, default = ""): string =
  if v.isNil: return default
  let f = v[key]
  if f.isNil: return default
  case f.kind
  of hkString: f.strVal
  of hkNumber: (if f.numVal == f.numVal.int.float: $f.numVal.int else: $f.numVal)
  of hkBool: $f.boolVal
  else: default

proc getBool*(v: HclValue, key: string, default = false): bool =
  if v.isNil: return default
  let f = v[key]
  if f.isNil or f.kind != hkBool: return default
  f.boolVal

proc getFloat*(v: HclValue, key: string, default = 0.0): float =
  if v.isNil: return default
  let f = v[key]
  if f.isNil or f.kind != hkNumber: return default
  f.numVal

proc getInt*(v: HclValue, key: string, default = 0): int =
  int(getFloat(v, key, default.float))

proc getStrList*(v: HclValue, key: string, default: seq[string] = @[]): seq[string] =
  ## Lista stringów pod `key`. Jeśli `key` to pojedynczy string (nie
  ## lista), zwraca listę jednoelementową -- wygodne dla pól, które w
  ## HCL mogą być zapisane jako `x = "a"` albo `x = ["a"]`.
  if v.isNil: return default
  let f = v[key]
  if f.isNil: return default
  case f.kind
  of hkList:
    result = @[]
    for item in f.listVal:
      if item.kind == hkString: result.add item.strVal
  of hkString:
    result = @[f.strVal]
  else:
    result = default

proc getBlock*(v: HclValue, key: string): HclValue {.inline.} =
  ## Zwraca RAW wartość pod `key` -- czyli `` v[key] ``. Dla klucza, pod
  ## którym jest dokładnie jeden blok, to ten blok (`kind == hkBlock`).
  ## Dla klucza z powtórzonymi blokami (skolapsowanymi w listę, patrz
  ## `setField`) to `kind == hkBlock` NIE JEST prawdą -- będzie
  ## `kind == hkList`, którą wywołujący musi rozpoznać sam (tak jak robi
  ## to np. `zlbpkg/modules.nim`), albo użyć `getBlocks` poniżej, która
  ## zawsze zwraca `seq[HclValue]` niezależnie od tego, czy pod kluczem
  ## był jeden blok, wiele, czy żaden. Ta funkcja celowo NIE unwrapuje
  ## automatycznie do "pierwszego bloku" -- to złamałoby dotychczasowe
  ## zachowanie zlb (`getBlock` == dawne `` `[]` ``), na którym opiera się
  ## test "powtórzone klucze bloków zwijają się w listę".
  v[key]

proc findBlock*(v: HclValue, key: string): HclValue {.inline.} =
  ## Alias `getBlock` -- nazwa używana historycznie w zpm. UWAGA: w zpm
  ## `findBlock` był zawsze wołany dla kluczy, które w praktyce mają co
  ## najwyżej jeden blok (np. `security { }`, `custom { }`) -- ten sam
  ## brak unwrappingu co w `getBlock` nie jest tam obserwowalny.
  getBlock(v, key)

proc getBlocks*(v: HclValue, key: string): seq[HclValue] =
  ## Wszystkie bloki pod `key` (np. każdy `repo "..." { }` w keys/default.hcl).
  result = @[]
  if v.isNil: return
  let f = v[key]
  if f.isNil: return
  if f.kind == hkBlock:
    result.add f
  elif f.kind == hkList:
    for item in f.listVal:
      if item.kind == hkBlock: result.add item

proc label*(v: HclValue): string =
  ## Etykieta bloku (np. `"zenit-own"` w `repo "zenit-own" { ... }`),
  ## pusty string jeśli blok nie ma etykiety albo `v` to `nil`.
  if v.isNil: return ""
  v.getStr("_label")

proc hasKey*(v: HclValue, key: string): bool =
  not v.isNil and v.kind == hkBlock and v.fields.hasKey(key)
