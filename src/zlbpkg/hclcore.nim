import std/tables
import hclnim as real

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

proc newBlock(): HclValue =
  HclValue(kind: hkBlock, fields: initOrderedTable[string, HclValue]())

proc setField(blk: HclValue, key: string, val: HclValue) =
  ## Powtórzone klucze (np. wiele bloków `package "x" {}`, albo wiele
  ## `module "a" {}` / `module "b" {}`) kolapsują w listę -- patrz
  ## `getBlocks`/`getBlock` (ten ostatni zwraca surową wartość, czyli dla
  ## powtórzonych kluczy `kind == hkList`, tak jak w dawnym własnym
  ## parserze). Zachowanie identyczne z poprzednią (ręcznie pisaną)
  ## implementacją -- testy (`tests/test_core.nim` w zlb, "powtórzone
  ## klucze bloków zwijają się w listę") się na to nie zmieniły.
  if blk.fields.hasKey(key):
    let existing = blk.fields[key]
    if existing.kind == hkList and existing.listVal.len > 0 and existing.listVal[0].kind == hkBlock:
      ## Trzeci (i kolejny) blok pod tym samym kluczem -- DOPISZ do już
      ## istniejącej listy zamiast zawijać ją w kolejną listę (to była
      ## luka względem starego, ręcznie pisanego parsera -- bez tej
      ## gałęzi 3+ powtórzone bloki zagnieżdżały listy zamiast się
      ## spłaszczać, patrz `tests/test_core.nim`, "parsuje package.list
      ## z blokami HCL", 3 bloki `package`).
      existing.listVal.add val
    else:
      blk.fields[key] = HclValue(kind: hkList, listVal: @[existing, val])
  else:
    blk.fields[key] = val

# ---------------------------------------------------------------------------
# Konwersja realnego AST (hclnim.HclNode) na HclValue
# ---------------------------------------------------------------------------

proc valueFromNode(n: real.HclNode): HclValue =
  case n.kind
  of real.nkString:
    result = HclValue(kind: hkString, strVal: n.strVal)
  of real.nkNumber:
    ## `numVal` jest zawsze wypełnione przez prawdziwą bibliotekę -- także
    ## dla liczb całkowitych (`newIntNode` ustawia `numVal: i.float`) --
    ## więc nie trzeba tu rozróżniać `isInt`.
    result = HclValue(kind: hkNumber, numVal: n.numVal)
  of real.nkBool:
    result = HclValue(kind: hkBool, boolVal: n.boolVal)
  of real.nkNull:
    ## `null` nie występował w starym, ręcznie pisanym parserze (gramatyka
    ## dotychczasowych plików .hcl w tym projekcie go nie używa) -- żeby
    ## nie wywalać się na czymś, co teraz realny parser już rozumie,
    ## reprezentujemy go jako pusty string (taki sam "brak wartości",
    ## jaki dawał wcześniej brakujący klucz przez `getStr(..., default)`).
    result = HclValue(kind: hkString, strVal: "")
  of real.nkList:
    var items: seq[HclValue] = @[]
    for it in n.items: items.add valueFromNode(it)
    result = HclValue(kind: hkList, listVal: items)
  of real.nkObject:
    ## Obiekt inline `{ key = val, ... }` używany jako WARTOŚĆ (nie blok)
    ## -- traktujemy go jak blok, żeby dało się użyć tych samych
    ## akcesorów (getStr/getBool/...) na jego polach, gdyby kiedyś któryś
    ## z plików .hcl w tym projekcie zaczął go używać. Dotychczasowe
    ## pliki .hcl tego projektu tego nie robią (używają prawdziwych
    ## bloków `name { ... }`, nie `name = { ... }`).
    result = newBlock()
    for (k, v) in n.fields:
      setField(result, k, valueFromNode(v))
  of real.nkHeredoc:
    result = HclValue(kind: hkString, strVal: n.heredocText)
  of real.nkExpr:
    ## Wyrażenia HCL2 (referencje/funkcje/interpolacje poza zwykłym
    ## stringiem) -- żaden plik .hcl tego projektu ich nie używa (patrz
    ## `getStr`, który operuje na literałach), ale zamiast się wywalać,
    ## oddajemy surowy tekst źródłowy, tak samo jak biblioteka robi to
    ## sama w `toJson`/`` `$` ``.
    result = HclValue(kind: hkString, strVal: n.exprSrc)
  else:
    raise newException(HclError, "nieoczekiwany typ węzła HCL jako wartość")

proc bodyToBlock(items: seq[real.HclNode]): HclValue =
  result = newBlock()
  for item in items:
    case item.kind
    of real.nkAttribute:
      setField(result, item.name, valueFromNode(item.value))
    of real.nkBlock:
      var inner = bodyToBlock(item.blockBody)
      if item.labels.len > 0:
        ## Tylko pierwsza etykieta -- dotychczasowy format (`repo "x" {}`,
        ## `module "x" {}`, `package "x" {}`) używa co najwyżej jednej.
        inner.fields["_label"] = HclValue(kind: hkString, strVal: item.labels[0])
      setField(result, item.blockType, inner)
    else:
      discard  # nkDocument/nkAttribute.value itd. nie występują na tym poziomie

proc parseHcl*(src: string): HclValue =
  ## Parsuje dokument HCL PRAWDZIWĄ biblioteką hcl-nim (`real.parseHcl`),
  ## zwracając wirtualny blok główny (root) -- jego `fields` to
  ## atrybuty/bloki najwyższego poziomu, dokładnie jak wcześniej. Rzuca
  ## `HclError` (z numerem linii w `.line`, o ile biblioteka go poda) przy
  ## błędzie leksykalnym/składniowym.
  var doc: real.HclNode
  try:
    doc = real.parseHcl(src)
  except real.HclLexError as e:
    var ex = newException(HclError, e.msg)
    ex.line = e.line
    raise ex
  except real.HclParseError as e:
    var ex = newException(HclError, e.msg)
    ex.line = e.line
    raise ex
  except real.HclError as e:
    var ex = newException(HclError, e.msg)
    ex.line = 0
    raise ex
  bodyToBlock(doc.body)

# ---------------------------------------------------------------------------
# Akcesory wygodne -- wspólne dla zpm/zlb/installer (niezmienione API)
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
  ## był jeden blok, wiele, czy żaden.
  v[key]

proc findBlock*(v: HclValue, key: string): HclValue {.inline.} =
  ## Alias `getBlock` -- nazwa używana historycznie w zpm.
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
