import std/[os, strutils, strformat]
import zlbpkg/types
import zlbpkg/manifest
import zlbpkg/paths
import zlbpkg/modules
import zlbpkg/rootfs
import zlbpkg/iso
import zlbpkg/oci
import zlbpkg/ci
import zlbpkg/keys
import zlbpkg/scaffold
import zlbpkg/crosscompile
import zlbpkg/installerconfig

const zlbVersion = "0.3.0"

proc usage() =
  echo """
ZLB -- Zenit Linux Builder v""" & zlbVersion & """

USAGE:
  zlb init [dir]                 scaffold a new distro project
  zlb build rootfs --arch ARCH   stage a rootfs (out/cache/rootfs/ARCH)
  zlb build iso    --arch ARCH   build a bootable ISO -> out/
  zlb build oci    --arch ARCH   build an OCI image layout -> out/oci/
  zlb build all    --arch ARCH   rootfs + iso + oci in one go

  --manifest=FILE   use FILE instead of distro.hcl (alternate build profiles,
                     conventionally under profiles/, e.g.
                     `--manifest=profiles/server.hcl` -- see zenit's
                     .github/workflows/build-server.yml)
  --toolset=NAME    override toolset.profile from distro.hcl for this build
                    only ("gnu" or "zenit" -- see distro.hcl's toolset { }
                    block; requires toolset.allow_override != false).
                    Only affects `zlb build rootfs`/`zlb build all`.
  --allow-placeholder  don't fail the build if 'zpm' can't be found or
                    downloaded -- simulate package installs instead (loudly
                    warned on every use). For inspecting the module tree
                    without a real zpm available, never for real releases.
                    Only affects `zlb build rootfs`/`zlb build all`.
  zlb modules list                list modules distro.hcl would include
  zlb manifest validate            validate manifest + modules/*/package.list
                                    (alias: `zlb validate`)
  zlb ci generate                  write CI workflow from workflow{} block
  zlb clean [--cache-only]         wipe out/ (or just out/cache/)
  zlb version                      print version

ARCH may be a single target (x86_64, aarch64, riscv64, armv7, armhf,
i686, ppc64le, s390x, loongarch64), "self" for the host architecture,
or "all" to build every arch listed in distro.hcl's distro { arch = [...] }
block.
"""

proc findProjectRoot(manifestFile: string): string =
  ## Walk up from cwd looking for `manifestFile` (domyślnie distro.hcl,
  ## v0.3: konfigurowalne przez `--manifest=<plik>` -- pozwala na
  ## ALTERNATYWNE profile budowania w tym samym repo, np.
  ## `devcontainer.hcl` obok głównego `distro.hcl` -- patrz zenit
  ## .github/workflows/build-devcontainer.yml).
  var dir = getCurrentDir()
  while true:
    if fileExists(dir / manifestFile): return dir
    let parent = parentDir(dir)
    if parent == dir: return getCurrentDir()  # give up, let loadManifest report the error
    dir = parent

proc parseFlag(args: seq[string], name: string, default: string): string =
  ## v0.3: obsługuje OBIE składnie -- "--flag wartość" (spacja) ORAZ
  ## "--flag=wartość" (znak równości) -- wcześniej tylko pierwsza
  ## działała, co jest niespójne z resztą narzędzi Zenit (zpm/zpk już
  ## akceptują obie formy) i cichym pułapem: `--manifest=devcontainer.hcl`
  ## było po cichu IGNOROWANE (parseFlag zwracał domyślne "distro.hcl"
  ## bez żadnego ostrzeżenia), więc CI mogło budować zupełnie inny
  ## manifest niż zamierzony bez żadnego komunikatu o błędzie.
  let eqPrefix = name & "="
  for a in args:
    if a.startsWith(eqPrefix):
      return a[eqPrefix.len .. ^1]
  for i, a in args:
    if a == name and i + 1 < args.len: return args[i + 1]
  default

proc hasFlag(args: seq[string], name: string): bool =
  ## Bezargumentowa flaga bool (np. `--allow-placeholder`) -- obecność w
  ## `args` znaczy true, brak znaczy false. W przeciwieństwie do
  ## `parseFlag` nie oczekuje żadnej wartości po fladze.
  name in args

proc resolveArches(m: Manifest, archFlag: string): seq[string] =
  if archFlag == "all":
    for a in m.distro.arches:
      result.add $resolveArch(a)
  elif archFlag == "self" or archFlag == "":
    result.add $hostArch()
  else:
    result.add archFlag

proc cmdInit(args: seq[string]) =
  let dir = if args.len > 0: args[0] else: "."
  scaffoldProject(dir)

proc loadProject(manifestFile: string = "distro.hcl"): tuple[m: Manifest, root: string, paths: ProjectPaths] =
  let root = findProjectRoot(manifestFile)
  let m = loadManifest(root / manifestFile)
  var p = resolveProjectPaths(root)
  ensureBaseDirs(p)
  (m, root, p)

proc cmdBuildRootfs(archFlag, manifestFile, toolsetFlag: string, allowPlaceholder: bool) =
  let (m, root, p) = loadProject(manifestFile)
  for a in resolveArches(m, archFlag):
    buildRootfs(p, m, root, a, toolsetFlag, allowPlaceholder)

proc cmdBuildIso(archFlag, manifestFile: string) =
  let (m, root, p) = loadProject(manifestFile)
  let installerCfg = loadInstallerConfig(root)
  if installerCfg.present:
    let desktopErrors = validateDesktops(root, installerCfg)
    if desktopErrors.len > 0:
      for e in desktopErrors: stderr.writeLine(&"✘ [installer] {e}")
      raise newException(ZlbError, "installer/config.hcl wymienia środowisko(a) graficzne bez odpowiadającego modułu -- popraw modules/desktop-<id>/ albo installer.desktops")
    let warnings = validateInstallerBranding(root, installerCfg)
    for w in warnings:
      echo &"==> [installer] Ostrzeżenie: {w}"
    echo &"==> [installer] installer/config.hcl znaleziony -- desktops={installerCfg.desktops}, " &
      &"default_desktop='{installerCfg.defaultDesktop}', branding: icon={installerCfg.brandingIcon}, " &
      &"banner={installerCfg.brandingBanner}"
  for a in resolveArches(m, archFlag):
    buildIsoImage(p, m, a, root / "overlays" / "branding")
    let sumsFile = p.finalPath(expand(m.iso.output, m, a)) & ".sha256"
    discard signRelease(m.keys.gpgKeyId, p.outDir, sumsFile)

proc cmdBuildOci(archFlag, manifestFile: string) =
  let (m, root, p) = loadProject(manifestFile)
  for a in resolveArches(m, archFlag):
    buildOciImage(p, m, a)

proc cmdBuildAll(archFlag, manifestFile, toolsetFlag: string, allowPlaceholder: bool) =
  let (m, root, p) = loadProject(manifestFile)
  for a in resolveArches(m, archFlag):
    buildRootfs(p, m, root, a, toolsetFlag, allowPlaceholder)
    buildIsoImage(p, m, a, root / "overlays" / "branding")
    buildOciImage(p, m, a)

proc cmdModulesList(manifestFile: string) =
  let (m, root, _) = loadProject(manifestFile)
  let mods = discoverModules(root / "modules", m.modules.includeMods)
  echo &"{mods.len} module(s) for {m.distro.name} {m.distro.version}:"
  for md in mods:
    echo &"  - {md.name}: {md.installList.len} install, {md.removeList.len} remove, {md.janetScripts.len} janet hook(s)"

proc cmdManifestValidate(manifestFile: string) =
  ## v0.3 -- POPRAWKA: `zlb manifest validate` jest referencjonowane w
  ## zenit/.github/workflows/setup.yml od zawsze, ale komenda NIGDY nie
  ## istniała w zlb.nim (case dispatch znał tylko init/build/modules/
  ## ci/clean/version/help) -- ten CI krok musiał się zawsze wywalać z
  ## "Unknown command: manifest". Teraz naprawdę parsuje manifest +
  ## wszystkie zadeklarowane moduły (`package.list`/`package.remove` w
  ## formacie HCL) i wypisuje czytelne podsumowanie, kończąc kodem != 0
  ## przy jakimkolwiek błędzie walidacji.
  let root = findProjectRoot(manifestFile)
  var m: Manifest
  try:
    m = loadManifest(root / manifestFile)
  except ZlbError as e:
    stderr.writeLine(&"✘ {manifestFile}: {e.msg}")
    quit(1)
  echo &"✔ {manifestFile}: {m.distro.name} {m.distro.version} (arch: {m.distro.arches.join(\", \")})"

  var mods: seq[ModulePackages]
  try:
    mods = discoverModules(root / "modules", m.modules.includeMods)
  except ZlbError as e:
    stderr.writeLine(&"✘ moduły ({m.modules.includeMods.join(\", \")}): {e.msg}")
    quit(1)
  var totalPkgs = 0
  for md in mods:
    totalPkgs += md.installList.len
    echo &"✔ modules/{md.name}: {md.installList.len} pakiet(ów), {md.removeList.len} do usunięcia, " &
      &"{md.janetScripts.len} hook(ów) janet"
  echo &"✔ Razem: {mods.len} moduł(ów), {totalPkgs} pakiet(ów) do zainstalowania."

  let installerCfg = loadInstallerConfig(root)
  if installerCfg.present:
    let desktopErrors = validateDesktops(root, installerCfg)
    for e in desktopErrors:
      stderr.writeLine(&"✘ installer/config.hcl: {e}")
    let warnings = validateInstallerBranding(root, installerCfg)
    if warnings.len == 0:
      echo "✔ installer/config.hcl: branding OK."
    for w in warnings:
      echo &"⚠ installer/config.hcl: {w}"
    if desktopErrors.len > 0:
      quit(1)
  echo "✔ Walidacja zakończona bez błędów."

proc cmdCiGenerate() =
  let (m, root, _) = loadProject()
  generateWorkflow(m, root)

proc cmdClean(cacheOnly: bool) =
  let root = findProjectRoot("distro.hcl")
  let p = resolveProjectPaths(root)
  if cacheOnly:
    removeDir(p.cacheDir)
    echo "Removed " & p.cacheDir
  else:
    removeDir(p.outDir)
    echo "Removed " & p.outDir

proc main() =
  let argv = commandLineParams()
  if argv.len == 0:
    usage()
    quit(0)

  let cmd = argv[0]
  let rest = argv[1..^1]
  let manifestFile = parseFlag(rest, "--manifest", "distro.hcl")

  try:
    case cmd
    of "init":
      cmdInit(rest)
    of "build":
      if rest.len == 0:
        usage(); quit(1)
      let archFlag = parseFlag(rest, "--arch", "self")
      let toolsetFlag = parseFlag(rest, "--toolset", "")
      let allowPlaceholder = hasFlag(rest, "--allow-placeholder")
      case rest[0]
      of "rootfs": cmdBuildRootfs(archFlag, manifestFile, toolsetFlag, allowPlaceholder)
      of "iso": cmdBuildIso(archFlag, manifestFile)
      of "oci": cmdBuildOci(archFlag, manifestFile)
      of "all": cmdBuildAll(archFlag, manifestFile, toolsetFlag, allowPlaceholder)
      else:
        echo "Unknown build target: " & rest[0]
        usage(); quit(1)
    of "modules":
      if rest.len > 0 and rest[0] == "list": cmdModulesList(manifestFile)
      else: usage(); quit(1)
    of "manifest":
      if rest.len > 0 and rest[0] == "validate": cmdManifestValidate(manifestFile)
      else: usage(); quit(1)
    of "validate":
      # Alias wygodny z linii poleceń -- `zlb manifest validate` to
      # nazwa "kanoniczna" (referencjonowana w istniejącym CI), ale
      # `zlb validate` jest krótsze do ręcznego wpisania.
      cmdManifestValidate(manifestFile)
    of "ci":
      if rest.len > 0 and rest[0] == "generate": cmdCiGenerate()
      else: usage(); quit(1)
    of "clean":
      cmdClean("--cache-only" in rest)
    of "version", "--version", "-v":
      echo "zlb " & zlbVersion
    of "help", "--help", "-h":
      usage()
    else:
      echo "Unknown command: " & cmd
      usage()
      quit(1)
  except ZlbError as e:
    stderr.writeLine("error: " & e.msg)
    quit(1)

when isMainModule:
  main()
