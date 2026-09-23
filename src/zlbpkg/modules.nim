import std/[os, strutils, sequtils, algorithm, strformat]
import ./types
import ./hcl

## v0.3 -- package.list/package.remove to teraz PLIKI HCL (zamiast
## własnego formatu tekstowego "nazwa -> backend"), zgodnie z życzeniem:
## "chce aby package.list mial wszystko to co wymienialem ale zamiast
## custom formatu+text zamiast tego wole uzycie stabilnego przejrzystego
## hcl". Gramatyka -- jeden blok `package "nazwa" { ... }` na pakiet:
##
##   package "base" {}
##
##   package "kernel" {
##     backend     = "own"
##     variant     = "testing"   # branch z own-repository.json (schema_version 2)
##     description = "domyślne jądro Linux"
##   }
##
##   package "git" {
##     backend = "apt"
##     variant = "debian.testing"   # bezpieczna instalacja cross-distro
##   }
##
## Powtórzone bloki `package "x" { }` w tym samym pliku zwijają się w
## LISTĘ (patrz `setField` w hcl.nim) -- to jest właściwość parsera HCL
## używana już przez `module "a" { }` / `module "b" { }` w distro.hcl.

## v0.4 -- opcjonalne pole `arch` w bloku `package "nazwa" { ... }`:
##
##   package "grub" {
##     backend = "apt"
##     arch    = "x86_64"          # albo: arch = "x86_64,aarch64"
##   }
##
## Brak pola `arch` (jak dotąd) = pakiet dotyczy WSZYSTKICH architektur.
## Filtrowanie dzieje się w `readListFile`/`discoverModule`, które biorą
## teraz docelową architekturę builda -- patrz `buildRootfs` w rootfs.nim.

proc parsePackageBlock(blk: HclValue): PackageEntry =
  let name = blk.getStr("_label")
  if name.len == 0:
    raise newException(ZlbError, "blok 'package' bez etykiety (oczekiwano: package \"nazwa\" { ... })")
  let backend = blk.getStr("backend", "")
  let variant = blk.getStr("variant", "")
  if variant.len > 0 and backend.len == 0:
    raise newException(ZlbError,
      &"package \"{name}\": pole 'variant' wymaga jawnie podanego 'backend' -- backend decyduje o " &
      "znaczeniu wariantu (branch dla \"own\", dystrybucja dla reszty)")
  let version = blk.getStr("version", "")
  if version.len > 0 and backend != "own":
    raise newException(ZlbError,
      &"package \"{name}\": pole 'version' działa TYLKO z backend = \"own\" (przypina konkretne " &
      "wydanie z own-repository.json, patrz resolveVersionPlaceholder w zpm) -- dla apt/dnf/pacman/" &
      "zypper przypinanie wersji ma zupełnie inną, natywną składnię tych menedżerów, nieobsługiwaną " &
      "jeszcze przez to pole")
  let archRaw = blk.getStr("arch", "")
  let arches = if archRaw.len == 0: @[]
               else: archRaw.split(',').mapIt(it.strip).filterIt(it.len > 0)
  PackageEntry(name: name, backend: backend, variant: variant, version: version,
               description: blk.getStr("description", ""), arches: arches)

proc appliesToArch(entry: PackageEntry, targetArch: string): bool =
  ## targetArch == "" -> brak konkretnej architektury builda (np. `zlb
  ## modules list` / `zlb manifest validate`, patrz wywołania w zlb.nim) --
  ## wtedy pokazujemy/walidujemy WSZYSTKIE pakiety, niezależnie od `arch`,
  ## zamiast mylnie odfiltrowywać cokolwiek, co ma ograniczenie per-arch.
  targetArch.len == 0 or entry.arches.len == 0 or targetArch in entry.arches

proc readListFile(path, targetArch: string): seq[PackageEntry] =
  result = @[]
  if not fileExists(path): return
  let raw = readFile(path).strip()
  if raw.len == 0: return

  var root: HclValue
  try:
    root = parseHcl(raw)
  except ZlbError as e:
    raise newException(ZlbError, &"{path}: {e.msg}")

  let pkgField = root["package"]
  if pkgField.isNil: return

  var parsed: seq[PackageEntry] = @[]
  if pkgField.kind == hkBlock:
    parsed.add parsePackageBlock(pkgField)
  elif pkgField.kind == hkList:
    for item in pkgField.listVal:
      if item.kind != hkBlock:
        raise newException(ZlbError, &"{path}: oczekiwano bloków 'package \"nazwa\" {{ ... }}'")
      parsed.add parsePackageBlock(item)

  for entry in parsed:
    if appliesToArch(entry, targetArch):
      result.add entry
    else:
      echo &"    (pomijam '{entry.name}' -- arch = \"{entry.arches.join(\",\")}\" nie obejmuje '{targetArch}')"

proc discoverModule*(modulesRoot, name, targetArch: string): ModulePackages =
  let dir = modulesRoot / name
  if not dirExists(dir):
    raise newException(ZlbError, "Module '" & name & "' listed in distro.hcl but " &
      dir & " does not exist")

  result.name = name
  result.installList = readListFile(dir / "package.list", targetArch)
  result.removeList = readListFile(dir / "package.remove", targetArch)

  let scriptsDir = dir / "scripts"
  result.janetScripts = @[]
  if dirExists(scriptsDir):
    for kind, path in walkDir(scriptsDir):
      if kind == pcFile and path.toLowerAscii.endsWith(".janet"):
        result.janetScripts.add path
      elif kind == pcFile:
        raise newException(ZlbError,
          "modules/" & name & "/scripts/ may only contain .janet files, found: " &
          extractFilename(path))
  # deterministic execution order (e.g. 10-x.janet before 20-y.janet)
  result.janetScripts.sort(cmp[string])

proc resolveToolsetProfile*(cfg: ToolsetConfig, cliOverride: string): ToolsetProfile =
  ## `cliOverride` to wartość `--toolset=<gnu|zenit>` z linii poleceń (pusty
  ## string = brak flagi -> użyj `cfg.profile` z distro.hcl). Rzuca
  ## `ZlbError`, jeśli ktoś poda `--toolset` mimo `toolset.allow_override
  ## = false` w distro.hcl -- to świadomy wybór dystrybucji, żeby CI/
  ## pipeline nie mogło po cichu zbudować "niewłaściwego" wariantu.
  if cliOverride.len == 0:
    return cfg.profile
  if not cfg.allowOverride:
    raise newException(ZlbError,
      "--toolset zostało podane, ale distro.hcl ma toolset.allow_override = false " &
      "-- ta dystrybucja świadomie nie pozwala nadpisywać profilu narzędzi z linii poleceń")
  case cliOverride.toLowerAscii
  of "gnu": tpGnu
  of "zenit", "own": tpZenit
  else:
    raise newException(ZlbError,
      "--toolset='" & cliOverride & "' nieznany -- oczekiwano \"gnu\" albo \"zenit\"")

proc resolveToolsetModule*(cfg: ToolsetConfig, profile: ToolsetProfile): string =
  case profile
  of tpGnu: cfg.gnuModule
  of tpZenit: cfg.zenitModule

proc withToolset*(includeMods: seq[string], toolsetModule: string): seq[string] =
  ## Dopisuje moduł toolsetu do `modules.include`, chyba że dystrybucja
  ## już go tam jawnie wymienia (pełna kontrola ręczna wygrywa) albo lista
  ## jest pusta (czyli "buduj wszystko co jest w modules/" -- toolset i
  ## tak zostanie znaleziony przez katalogowe skanowanie w
  ## `discoverModules`, dopisywanie go jawnie tylko zduplikowałoby wpis).
  if includeMods.len == 0 or toolsetModule in includeMods:
    return includeMods
  result = includeMods
  result.add toolsetModule

proc discoverModules*(modulesRoot, targetArch: string, includeMods: seq[string]): seq[ModulePackages] =
  result = @[]
  if includeMods.len == 0:
    # nothing declared explicitly: build every directory found under modules/
    if not dirExists(modulesRoot): return
    var names: seq[string] = @[]
    for kind, path in walkDir(modulesRoot):
      if kind == pcDir: names.add extractFilename(path)
    names.sort(cmp[string])
    for n in names:
      result.add discoverModule(modulesRoot, n, targetArch)
  else:
    for n in includeMods:
      result.add discoverModule(modulesRoot, n, targetArch)

proc totalInstallCount*(mods: seq[ModulePackages]): int =
  for m in mods: result += m.installList.len

proc totalRemoveCount*(mods: seq[ModulePackages]): int =
  for m in mods: result += m.removeList.len
