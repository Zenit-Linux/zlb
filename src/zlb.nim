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

const zlbVersion = "0.1.0"

proc usage() =
  echo """
ZLB -- Zenith Linux Builder v""" & zlbVersion & """

USAGE:
  zlb init [dir]                 scaffold a new distro project
  zlb build rootfs --arch ARCH   stage a rootfs (out/cache/rootfs/ARCH)
  zlb build iso    --arch ARCH   build a bootable ISO -> out/
  zlb build oci    --arch ARCH   build an OCI image layout -> out/oci/
  zlb build all    --arch ARCH   rootfs + iso + oci in one go
  zlb modules list                list modules distro.hcl would include
  zlb ci generate                  write CI workflow from workflow{} block
  zlb clean [--cache-only]         wipe out/ (or just out/cache/)
  zlb version                      print version

ARCH may be a single target (x86_64, aarch64, riscv64, armv7, armhf,
i686, ppc64le, s390x, loongarch64), "self" for the host architecture,
or "all" to build every arch listed in distro.hcl's distro { arch = [...] }
block.
"""

proc findProjectRoot(): string =
  ## Walk up from cwd looking for distro.hcl, like `git rev-parse --show-toplevel`.
  var dir = getCurrentDir()
  while true:
    if fileExists(dir / "distro.hcl"): return dir
    let parent = parentDir(dir)
    if parent == dir: return getCurrentDir()  # give up, let loadManifest report the error
    dir = parent

proc parseFlag(args: seq[string], name: string, default: string): string =
  for i, a in args:
    if a == name and i + 1 < args.len: return args[i + 1]
  default

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

proc loadProject(): tuple[m: Manifest, root: string, paths: ProjectPaths] =
  let root = findProjectRoot()
  let m = loadManifest(root / "distro.hcl")
  var p = resolveProjectPaths(root)
  ensureBaseDirs(p)
  (m, root, p)

proc cmdBuildRootfs(archFlag: string) =
  let (m, root, p) = loadProject()
  for a in resolveArches(m, archFlag):
    buildRootfs(p, m, root, a)

proc cmdBuildIso(archFlag: string) =
  let (m, root, p) = loadProject()
  for a in resolveArches(m, archFlag):
    buildIsoImage(p, m, a, root / "overlays" / "branding")
    let sumsFile = p.finalPath(expand(m.iso.output, m, a)) & ".sha256"
    discard signRelease(m.keys.gpgKeyId, p.outDir, sumsFile)

proc cmdBuildOci(archFlag: string) =
  let (m, root, p) = loadProject()
  for a in resolveArches(m, archFlag):
    buildOciImage(p, m, a)

proc cmdBuildAll(archFlag: string) =
  let (m, root, p) = loadProject()
  for a in resolveArches(m, archFlag):
    buildRootfs(p, m, root, a)
    buildIsoImage(p, m, a, root / "overlays" / "branding")
    buildOciImage(p, m, a)

proc cmdModulesList() =
  let (m, root, _) = loadProject()
  let mods = discoverModules(root / "modules", m.modules.includeMods)
  echo &"{mods.len} module(s) for {m.distro.name} {m.distro.version}:"
  for md in mods:
    echo &"  - {md.name}: {md.installList.len} install, {md.removeList.len} remove, {md.janetScripts.len} janet hook(s)"

proc cmdCiGenerate() =
  let (m, root, _) = loadProject()
  generateWorkflow(m, root)

proc cmdClean(cacheOnly: bool) =
  let root = findProjectRoot()
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

  try:
    case cmd
    of "init":
      cmdInit(rest)
    of "build":
      if rest.len == 0:
        usage(); quit(1)
      let archFlag = parseFlag(rest, "--arch", "self")
      case rest[0]
      of "rootfs": cmdBuildRootfs(archFlag)
      of "iso": cmdBuildIso(archFlag)
      of "oci": cmdBuildOci(archFlag)
      of "all": cmdBuildAll(archFlag)
      else:
        echo "Unknown build target: " & rest[0]
        usage(); quit(1)
    of "modules":
      if rest.len > 0 and rest[0] == "list": cmdModulesList()
      else: usage(); quit(1)
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
