import std/[os, strutils, algorithm, strformat]
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
  PackageEntry(name: name, backend: backend, variant: variant,
               description: blk.getStr("description", ""))

proc readListFile(path: string): seq[PackageEntry] =
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

  if pkgField.kind == hkBlock:
    result.add parsePackageBlock(pkgField)
  elif pkgField.kind == hkList:
    for item in pkgField.listVal:
      if item.kind != hkBlock:
        raise newException(ZlbError, &"{path}: oczekiwano bloków 'package \"nazwa\" {{ ... }}'")
      result.add parsePackageBlock(item)

proc discoverModule*(modulesRoot, name: string): ModulePackages =
  let dir = modulesRoot / name
  if not dirExists(dir):
    raise newException(ZlbError, "Module '" & name & "' listed in distro.hcl but " &
      dir & " does not exist")

  result.name = name
  result.installList = readListFile(dir / "package.list")
  result.removeList = readListFile(dir / "package.remove")

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

proc discoverModules*(modulesRoot: string, includeMods: seq[string]): seq[ModulePackages] =
  result = @[]
  if includeMods.len == 0:
    # nothing declared explicitly: build every directory found under modules/
    if not dirExists(modulesRoot): return
    var names: seq[string] = @[]
    for kind, path in walkDir(modulesRoot):
      if kind == pcDir: names.add extractFilename(path)
    names.sort(cmp[string])
    for n in names:
      result.add discoverModule(modulesRoot, n)
  else:
    for n in includeMods:
      result.add discoverModule(modulesRoot, n)

proc totalInstallCount*(mods: seq[ModulePackages]): int =
  for m in mods: result += m.installList.len

proc totalRemoveCount*(mods: seq[ModulePackages]): int =
  for m in mods: result += m.removeList.len
