import std/[os, strformat, strutils]
import ./types
import ./paths
import ./manifest
import ./modules
import ./overlay
import ./zpm
import ./tools
import ./janetrunner
import ./crosscompile
import ./installerconfig

proc bootstrapSeed(p: ProjectPaths, m: Manifest, arch: string) =
  let rootfs = p.rootfsDir(arch)
  if dirExists(rootfs) and dirExists(rootfs / "etc"):
    echo &"==> [{arch}] reusing cached rootfs at {rootfs} (delete out/cache/rootfs/{arch} to force a clean bootstrap)"
    return

  createDir(rootfs)

  if m.distro.base == "self":
    let seed = seedTarballPath(p.cacheDir, parseEnum[Arch](arch), m.distro.version)
    if fileExists(seed):
      echo &"==> [{arch}] extracting self-seed {seed}"
      let tarBin = findExe("tar")
      if tarBin.len == 0:
        raise newException(ZlbError, "'tar' not found on PATH")
      discard execShellCmd(&"tar -C \"{rootfs}\" -xf \"{seed}\"")
    else:
      echo &"==> [{arch}] no cached self-seed found at {seed}"
      echo "    First-ever build for this arch has nothing to bootstrap from yet."
      echo "    Creating a minimal empty rootfs skeleton -- zpm placeholder will"
      echo "    log the packages it *would* install once it's implemented."
      for d in ["etc", "usr/bin", "usr/lib", "var", "boot", "home", "root", "tmp"]:
        createDir(rootfs / d)
  else:
    echo &"==> [{arch}] foreign bootstrap requested (base = \"{m.distro.base}\") -- not yet implemented, creating skeleton"
    for d in ["etc", "usr/bin", "usr/lib", "var", "boot", "home", "root", "tmp"]:
      createDir(rootfs / d)

# `embedInstaller` (kopiowanie osobno pobranej binarki instalatora do
# rootfs) USUNIĘTE, v0.4 -- `installer` trafia do rootfs DOKŁADNIE tak
# samo jak każdy inny pakiet: przez `package "installer" { backend = "own" }`
# w modules/core/package.list, instalowany normalnym `zpm install` w
# ramach reszty pakietów modułu (patrz buildRootfs niżej). Nie ma już
# osobnej binarki "installer" w cache narzędzi do skądś skopiować --
# zlbpkg/tools.nim pobiera już TYLKO zpm samo, patrz jego nagłówek.

proc resolveIncludeModsWithToolset(m: Manifest, projectRoot, toolsetOverride: string): seq[string] =
  ## Dopisuje moduł toolsetu (toolset-gnu/toolset-zenit, patrz
  ## `manifest.nim::toolset { }` i `modules.nim::resolveToolsetModule`) do
  ## `modules.include`, ALE tylko jeśli odpowiadający katalog
  ## `modules/<toolset-module>/` faktycznie istnieje w projekcie -- tak
  ## jak reszta zlb (patrz `installerCfg.present`), ta funkcja degraduje
  ## się cicho do no-op, gdy projekt świadomie nie korzysta z tego
  ## mechanizmu (np. devcontainer.hcl, gdzie coreutils przychodzi
  ## tranzytywnie z pakietu "base" i wybór toolsetu nie ma znaczenia).
  let profile = resolveToolsetProfile(m.toolset, toolsetOverride)
  let toolsetModule = resolveToolsetModule(m.toolset, profile)
  if dirExists(projectRoot / "modules" / toolsetModule):
    result = withToolset(m.modules.includeMods, toolsetModule)
    if toolsetModule notin m.modules.includeMods:
      echo &"==> [toolset] profil '{profile}' -> dołączono moduł 'modules/{toolsetModule}'"
  else:
    result = m.modules.includeMods

proc embedInstallerConfig(projectRoot, rootfs: string, cfg: InstallerConfig) =
  ## Kopiuje `installer/config.hcl` (verbatim -- ten sam plik, ten sam
  ## format) i pliki brandingu, które wskazuje, do rootfsu -- pod
  ## ścieżkami z `types.InstallerEmbeddedConfigPath`/
  ## `InstallerEmbeddedBrandingDir`. Zenit Installer czyta ten plik w
  ## trakcie działania (patrz `installerpkg/config.nim` w repo
  ## `installer`) tym samym parserem hcl-nim -- to jest właściwe miejsce,
  ## w którym "wybór środowisk graficznych i lokalizacji z
  ## installer/config.hcl" faktycznie trafia do kreatora, a nie tylko do
  ## dokumentacji. No-op (z komunikatem), jeśli projekt nie ma
  ## installer/config.hcl w ogóle -- to NIE błąd builda (np. obrazy
  ## kontenerowe/serwerowe bez instalatora).
  if not cfg.present:
    echo "==> [installer] brak installer/config.hcl w projekcie -- pomijam embedowanie configu/brandingu"
    return

  let destConfigPath = rootfs / InstallerEmbeddedConfigPath
  createDir(parentDir(destConfigPath))
  copyFileWithPermissions(projectRoot / "installer" / "config.hcl", destConfigPath)
  echo &"==> [installer] osadzono config w {destConfigPath}"

  let brandingSrcDir = projectRoot / "overlays" / "branding"
  let brandingDestDir = rootfs / InstallerEmbeddedBrandingDir
  var copied = 0
  for fname in [cfg.brandingIcon, cfg.brandingBanner]:
    if fname.len == 0: continue
    let src = brandingSrcDir / fname
    if not fileExists(src): continue  # już zaraportowane przez validateInstallerBranding
    createDir(brandingDestDir)
    copyFileWithPermissions(src, brandingDestDir / fname)
    inc copied
  if copied > 0:
    echo &"==> [installer] osadzono {copied} plik(ów) brandingu w {brandingDestDir}"

proc buildRootfs*(p: ProjectPaths, m: Manifest, projectRoot, arch: string, toolsetOverride = "", allowPlaceholder = false) =
  ensureBuildTools(p, allowPlaceholder)

  echo &"==> [{arch}] bootstrapping"
  bootstrapSeed(p, m, arch)
  let rootfs = p.rootfsDir(arch)

  let archEnum = parseEnum[Arch](arch)
  if needsEmulation(archEnum):
    installQemuIntoRootfs(rootfs, archEnum)

  echo &"==> [{arch}] discovering modules"
  let includeMods = resolveIncludeModsWithToolset(m, projectRoot, toolsetOverride)
  let mods = discoverModules(projectRoot / "modules", includeMods)
  echo &"    {mods.len} module(s), {totalInstallCount(mods)} package(s) to install, {totalRemoveCount(mods)} to remove"

  let defaultBackend = backendForBase(m)
  echo &"==> [{arch}] default zpm backend for base '{m.distro.base}': {defaultBackend}"

  discard zpmInit(rootfs, projectRoot / m.keys.zpmKeyList)

  for md in mods:
    echo &"==> [{arch}] module '{md.name}'"
    runModuleHooks(md.janetScripts, rootfs, md.name, arch, m.distro.name, m.distro.version, hsPrePackages)
    if not zpmInstall(rootfs, md.installList, defaultBackend):
      raise newException(ZlbError, &"zpm install failed for module '{md.name}'")
    if not zpmRemove(rootfs, md.removeList, defaultBackend):
      raise newException(ZlbError, &"zpm remove failed for module '{md.name}'")
    runModuleHooks(md.janetScripts, rootfs, md.name, arch, m.distro.name, m.distro.version, hsPostPackages)

  echo &"==> [{arch}] applying overlays"
  applyAllOverlays(projectRoot, rootfs, p.stagingDir(arch))

  # `installer` binarka trafia do rootfs wcześniej, w normalnej pętli
  # instalacji pakietów modułu "core" (zpm install ... installer -> own),
  # nie tutaj -- ten krok zajmuje się TYLKO configiem/brandingiem
  # instalatora (installer/config.hcl + overlays/branding), nie samą binarką.
  embedInstallerConfig(projectRoot, rootfs, loadInstallerConfig(projectRoot))

  for md in mods:
    runModuleHooks(md.janetScripts, rootfs, md.name, arch, m.distro.name, m.distro.version, hsPostOverlay)

  discard zpmSync(rootfs)

  echo &"==> [{arch}] rootfs ready: {rootfs}"
