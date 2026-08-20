import std/os
import ./types

proc copyTree(src, dst: string) =
  if not dirExists(src): return
  createDir(dst)
  for kind, path in walkDir(src):
    let rel = extractFilename(path)
    let target = dst / rel
    case kind
    of pcDir:
      copyTree(path, target)
    of pcFile:
      createDir(parentDir(target))
      copyFileWithPermissions(path, target)
    of pcLinkToFile, pcLinkToDir:
      # preserve symlinks instead of following them (important for
      # things like /usr/bin/sh -> busybox style overlays)
      let linkTarget = expandSymlink(path)
      if symlinkExists(target): removeFile(target)
      createSymlink(linkTarget, target)

proc resolveOverlayPaths*(distroRoot: string): OverlayPaths =
  result.brandingDir = distroRoot / "overlays" / "branding"
  result.homeDir = distroRoot / "overlays" / "home"
  result.systemDir = distroRoot / "overlays" / "system"

proc applySystemOverlay*(ov: OverlayPaths, rootfs: string) =
  copyTree(ov.systemDir, rootfs)

proc applyHomeOverlay*(ov: OverlayPaths, rootfs: string) =
  copyTree(ov.homeDir, rootfs / "etc" / "skel")

proc stageBranding*(ov: OverlayPaths, stagingDir: string) =
  ## Branding assets aren't part of the rootfs itself -- they're staged
  ## next to the ISO build tree so the installer (Zenith Installer) can
  ## pick them up at boot time.
  copyTree(ov.brandingDir, stagingDir / "branding")

proc applyAllOverlays*(distroRoot, rootfs, stagingDir: string) =
  let ov = resolveOverlayPaths(distroRoot)
  applySystemOverlay(ov, rootfs)
  applyHomeOverlay(ov, rootfs)
  stageBranding(ov, stagingDir)
