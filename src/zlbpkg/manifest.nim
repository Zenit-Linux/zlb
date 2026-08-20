import std/[os, strutils]
import ./types
import ./hcl

proc toArch(s: string): Arch =
  case s.toLowerAscii
  of "x86_64", "amd64": archX86_64
  of "aarch64", "arm64": archAarch64
  of "riscv64": archRiscv64
  of "self": archSelf
  else:
    raise newException(ZlbError, "Unknown architecture in distro.hcl: '" & s & "'")

proc toBootMode(s: string): BootMode =
  case s.toLowerAscii
  of "bios": bmBios
  of "uefi": bmUefi
  else: bmHybrid

proc loadManifest*(path: string): Manifest =
  if not fileExists(path):
    raise newException(ZlbError, "Manifest not found: " & path &
      " (run 'zlb init' to scaffold a new distro)")

  let src = readFile(path)
  let root = parseHcl(src)

  result = Manifest()

  # ---- distro { } -----------------------------------------------------
  let distroBlk = root.getBlock("distro")
  if distroBlk.isNil:
    raise newException(ZlbError, "distro.hcl is missing the required 'distro { }' block")

  result.distro.name = distroBlk.getStr("name", "Zenith Linux")
  result.distro.codename = distroBlk.getStr("codename", "unnamed")
  result.distro.version = distroBlk.getStr("version", "0.0.0")
  result.distro.base = distroBlk.getStr("base", "self")

  let archStrs = distroBlk.getStrList("arch")
  if archStrs.len == 0:
    result.distro.arches = @[archSelf]
  else:
    for a in archStrs:
      result.distro.arches.add toArch(a)

  # ---- modules { } ------------------------------------------------------
  let modBlk = root.getBlock("modules")
  if not modBlk.isNil:
    result.modules.includeMods = modBlk.getStrList("include")

  # ---- iso { } ------------------------------------------------------------
  let isoBlk = root.getBlock("iso")
  if not isoBlk.isNil:
    result.iso.bootloader = isoBlk.getStr("bootloader", "grub")
    result.iso.bootMode = toBootMode(isoBlk.getStr("boot_mode", "hybrid"))
    result.iso.compression = isoBlk.getStr("compression", "xz")
    result.iso.output = isoBlk.getStr("output",
      "zenith-linux-${version}-${arch}.iso")
  else:
    result.iso.bootloader = "grub"
    result.iso.bootMode = bmHybrid
    result.iso.compression = "xz"
    result.iso.output = "zenith-linux-${version}-${arch}.iso"

  # ---- oci { } ------------------------------------------------------------
  let ociBlk = root.getBlock("oci")
  if not ociBlk.isNil:
    result.oci.registry = ociBlk.getStr("registry", "ghcr.io/zenith-linux")
    result.oci.repository = ociBlk.getStr("repository", result.distro.name.toLowerAscii.replace(" ", "-"))
    result.oci.tag = ociBlk.getStr("tag", "${version}")
    result.oci.output = ociBlk.getStr("output", "zenith-linux-${version}-${arch}-oci")
  else:
    result.oci.registry = "ghcr.io/zenith-linux"
    result.oci.repository = result.distro.name.toLowerAscii.replace(" ", "-")
    result.oci.tag = "${version}"
    result.oci.output = "zenith-linux-${version}-${arch}-oci"

  # ---- keys { } -----------------------------------------------------------
  let keysBlk = root.getBlock("keys")
  if not keysBlk.isNil:
    result.keys.gpgKey = keysBlk.getStr("gpg_key", "keys/zenith-release.asc")
    result.keys.gpgKeyId = keysBlk.getStr("gpg_key_id", "")
    result.keys.zpmKeyList = keysBlk.getStr("zpm_key_list", "keys/default.hcl")
  else:
    result.keys.gpgKey = "keys/zenith-release.asc"
    result.keys.zpmKeyList = "keys/default.hcl"

  # ---- workflow { } ---------------------------------------------------
  let wfBlk = root.getBlock("workflow")
  if not wfBlk.isNil:
    result.workflow.provider = wfBlk.getStr("provider", "github")
    result.workflow.triggers = wfBlk.getStrList("triggers")
    let matrix = wfBlk.getStrList("matrix_arch")
    for a in matrix:
      result.workflow.matrixArches.add toArch(a)
    if result.workflow.matrixArches.len == 0:
      result.workflow.matrixArches = result.distro.arches
  else:
    result.workflow.provider = "github"
    result.workflow.triggers = @["push", "tag"]
    result.workflow.matrixArches = result.distro.arches

proc expand*(templ: string, m: Manifest, arch: string): string =
  ## Very small ${var} interpolation used for filename templates.
  result = templ
  result = result.replace("${version}", m.distro.version)
  result = result.replace("${codename}", m.distro.codename)
  result = result.replace("${name}", m.distro.name.toLowerAscii.replace(" ", "-"))
  result = result.replace("${arch}", arch)
