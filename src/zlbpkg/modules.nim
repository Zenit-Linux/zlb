import std/[os, strutils, algorithm]
import ./types

proc parsePackageEntry(raw: string): PackageEntry =
  ## Rozumie zarówno zwykłe nazwy pakietów jak i jawne wymuszenie
  ## backendu zpm:
  ##   systemd                -> PackageEntry(name: "systemd", backend: "")
  ##   systemd -> apt          -> PackageEntry(name: "systemd", backend: "apt")
  ##   systemd -> dnf           # dowolny backend znany zpm: apt, dnf,
  ##                            # pacman, zypper, flatpak, snap, brew,
  ##                            # cargo, pip, npm, own
  var line = raw.strip()
  if "->" in line:
    let parts = line.split("->", maxsplit = 1)
    return PackageEntry(name: parts[0].strip(), backend: parts[1].strip().toLowerAscii)
  PackageEntry(name: line, backend: "")

proc readListFile(path: string): seq[PackageEntry] =
  result = @[]
  if not fileExists(path): return
  for rawLine in readFile(path).splitLines:
    let line = rawLine.strip()
    if line.len == 0: continue
    if line.startsWith("#"): continue        # comments allowed
    result.add parsePackageEntry(line)

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
