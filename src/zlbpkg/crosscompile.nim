import std/[os, osproc, strformat, strutils]
import ./types

proc hostArch*(): Arch =
  when defined(amd64):
    archX86_64
  elif defined(arm64):
    archAarch64
  elif defined(arm):
    archArmv7
  elif defined(riscv64):
    archRiscv64
  elif defined(i386):
    archI686
  elif defined(powerpc64) and defined(littleEndian):
    archPpc64le
  else:
    archX86_64

proc resolveArch*(a: Arch): Arch =
  if a == archSelf: hostArch() else: a

proc targetTriple*(a: Arch): string =
  case resolveArch(a)
  of archX86_64:  "x86_64-zenith-linux-gnu"
  of archAarch64: "aarch64-zenith-linux-gnu"
  of archRiscv64: "riscv64-zenith-linux-gnu"
  of archArmv7:   "armv7-zenith-linux-gnueabihf"
  of archArmhf:   "arm-zenith-linux-gnueabihf"
  of archI686:    "i686-zenith-linux-gnu"
  of archPpc64le: "powerpc64le-zenith-linux-gnu"
  of archS390x:   "s390x-zenith-linux-gnu"
  of archLoong64: "loongarch64-zenith-linux-gnu"
  of archSelf:    targetTriple(hostArch())

proc qemuBinary*(a: Arch): string =
  ## Static qemu-user binary name registered with binfmt_misc, e.g.
  ## qemu-aarch64-static. Empty string means "no emulation needed"
  ## (native arch).
  if resolveArch(a) == hostArch(): return ""
  case resolveArch(a)
  of archX86_64:  "qemu-x86_64-static"
  of archAarch64: "qemu-aarch64-static"
  of archRiscv64: "qemu-riscv64-static"
  of archArmv7:   "qemu-arm-static"
  of archArmhf:   "qemu-arm-static"
  of archI686:    "qemu-i386-static"
  of archPpc64le: "qemu-ppc64le-static"
  of archS390x:   "qemu-s390x-static"
  of archLoong64: "qemu-loongarch64-static"
  of archSelf: ""

proc needsEmulation*(a: Arch): bool = qemuBinary(a).len > 0

proc installQemuIntoRootfs*(rootfs: string, a: Arch) =
  ## Copies the static qemu-user interpreter into rootfs/usr/bin so
  ## `chroot rootfs <cmd>` transparently runs target-arch binaries.
  let qbin = qemuBinary(a)
  if qbin.len == 0: return
  let src = findExe(qbin)
  if src.len == 0:
    raise newException(ZlbError,
      &"Cross build for {resolveArch(a)} needs '{qbin}' on the host PATH " &
      "(install the qemu-user-static package)")
  createDir(rootfs / "usr" / "bin")
  copyFileWithPermissions(src, rootfs / "usr" / "bin" / qbin)
  echo &"  -> installed {qbin} into rootfs for {resolveArch(a)} emulation"

proc chrootExec*(rootfs: string, args: seq[string]): bool =
  let full = @["chroot", rootfs] & args
  let (output, code) = execCmdEx(full.join(" "))
  echo output
  code == 0

proc seedTarballPath*(cacheDir: string, a: Arch, version: string): string =
  ## Where a previously-built "self" bootstrap seed for this arch is
  ## expected to live, e.g. out/cache/seeds/aarch64-1.0.0.tar.zst
  cacheDir / "seeds" / &"{resolveArch(a)}-{version}.tar.zst"
