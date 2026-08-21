import std/[os, osproc, strformat, strutils]
import ./types
import ./paths
import ./manifest

proc run(cmd: string, args: seq[string]) =
  echo "  $ " & cmd & " " & args.join(" ")
  let p = startProcess(cmd, args = args, options = {poUsePath, poParentStreams})
  let code = p.waitForExit()
  close(p)
  if code != 0:
    raise newException(ZlbError, &"command failed ({code}): {cmd} {args.join(\" \")}")

proc requireExe(name: string): string =
  let e = findExe(name)
  if e.len == 0:
    raise newException(ZlbError, &"required tool '{name}' not found on PATH")
  e

proc squashRootfs(rootfs, outSfs: string) =
  createDir(parentDir(outSfs))
  let mksquash = requireExe("mksquashfs")
  if fileExists(outSfs): removeFile(outSfs)
  run(mksquash, @[rootfs, outSfs, "-comp", "xz", "-noappend"])

proc layoutIsoTree(p: ProjectPaths, arch: string, sfsPath, brandingDir: string): string =
  let isoTree = p.workDir(arch) / "isotree"
  removeDir(isoTree)
  createDir(isoTree / "zenith" / arch)
  createDir(isoTree / "boot" / "grub")
  copyFileWithPermissions(sfsPath, isoTree / "zenith" / arch / "airootfs.sfs")
  if dirExists(brandingDir):
    createDir(isoTree / "branding")
    for kind, path in walkDir(brandingDir):
      let dst = isoTree / "branding" / extractFilename(path)
      if kind == pcFile: copyFileWithPermissions(path, dst)
  isoTree

proc writeGrubCfg(isoTree, distroName, arch: string) =
  let cfgPath = isoTree / "boot" / "grub" / "grub.cfg"
  ## `installer=1` na linii poleceń jądra jest tym, co (w zenith-main's
  ## overlays/system/usr/local/bin/zenith-session-select) odróżnia sesję
  ## live-only od pełnoekranowego Zenith Installer -- podobnie jak
  ## najnowsze Fedory oferują "Start Fedora" vs "Install Fedora" wprost
  ## z GRUB-a, zamiast dopiero z poziomu pulpitu live.
  let cfg = &"""
set timeout=5
set default=0

menuentry "Try/Live {distroName} ({arch})" {{
  linux /boot/vmlinuz-linux boot=zenith arch={arch} quiet
  initrd /boot/initramfs-linux.img
}}

menuentry "Install {distroName} ({arch})" {{
  linux /boot/vmlinuz-linux boot=zenith arch={arch} installer=1 quiet
  initrd /boot/initramfs-linux.img
}}

menuentry "{distroName} ({arch}) - Safe graphics" {{
  linux /boot/vmlinuz-linux boot=zenith arch={arch} nomodeset
  initrd /boot/initramfs-linux.img
}}
"""
  writeFile(cfgPath, cfg)

proc buildIsoImage*(p: ProjectPaths, m: Manifest, arch: string, brandingDir: string) =
  let rootfs = p.rootfsDir(arch)
  if not dirExists(rootfs):
    raise newException(ZlbError, &"no staged rootfs for {arch} at {rootfs} -- run 'zlb build rootfs' first")

  echo &"==> [{arch}] squashing rootfs"
  let sfs = p.workDir(arch) / "airootfs.sfs"
  squashRootfs(rootfs, sfs)

  echo &"==> [{arch}] laying out ISO tree"
  let isoTree = layoutIsoTree(p, arch, sfs, brandingDir)
  writeGrubCfg(isoTree, m.distro.name, arch)

  let outFile = p.finalPath(expand(m.iso.output, m, arch))
  createDir(parentDir(outFile))

  echo &"==> [{arch}] writing ISO -> {outFile}"
  case m.iso.bootloader
  of "grub":
    let grubMkrescue = requireExe("grub-mkrescue")
    run(grubMkrescue, @["-o", outFile, isoTree])
  else:
    # generic fallback: plain El Torito-less data ISO via xorriso, good
    # enough for OCI-first / netboot-only profiles that skip a local
    # bootloader entirely.
    let xorriso = requireExe("xorriso")
    run(xorriso, @["-as", "mkisofs", "-r", "-J", "-V", m.distro.name,
                    "-o", outFile, isoTree])

  echo &"==> [{arch}] hashing"
  let sha = execProcess("sha256sum", args = @[outFile], options = {poUsePath})
  writeFile(outFile & ".sha256", sha)

  echo &"==> [{arch}] ISO complete: {outFile}"
