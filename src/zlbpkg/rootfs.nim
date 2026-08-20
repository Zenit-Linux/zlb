import std/[os, strformat, strutils]
import ./types
import ./paths
import ./manifest
import ./modules
import ./overlay
import ./zpm
import ./janetrunner
import ./crosscompile

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

proc buildRootfs*(p: ProjectPaths, m: Manifest, projectRoot, arch: string) =
  echo &"==> [{arch}] bootstrapping"
  bootstrapSeed(p, m, arch)
  let rootfs = p.rootfsDir(arch)

  let archEnum = parseEnum[Arch](arch)
  if needsEmulation(archEnum):
    installQemuIntoRootfs(rootfs, archEnum)

  echo &"==> [{arch}] discovering modules"
  let mods = discoverModules(projectRoot / "modules", m.modules.includeMods)
  echo &"    {mods.len} module(s), {totalInstallCount(mods)} package(s) to install, {totalRemoveCount(mods)} to remove"

  discard zpmInit(rootfs, projectRoot / m.keys.zpmKeyList)

  for md in mods:
    echo &"==> [{arch}] module '{md.name}'"
    runModuleHooks(md.janetScripts, rootfs, md.name, arch, m.distro.name, m.distro.version, hsPrePackages)
    if not zpmInstall(rootfs, md.installList):
      raise newException(ZlbError, &"zpm install failed for module '{md.name}'")
    if not zpmRemove(rootfs, md.removeList):
      raise newException(ZlbError, &"zpm remove failed for module '{md.name}'")
    runModuleHooks(md.janetScripts, rootfs, md.name, arch, m.distro.name, m.distro.version, hsPostPackages)

  echo &"==> [{arch}] applying overlays"
  applyAllOverlays(projectRoot, rootfs, p.stagingDir(arch))

  for md in mods:
    runModuleHooks(md.janetScripts, rootfs, md.name, arch, m.distro.name, m.distro.version, hsPostOverlay)

  discard zpmSync(rootfs)

  echo &"==> [{arch}] rootfs ready: {rootfs}"
