import std/[os, strutils]
import ./types

const distroHclTemplate = """
# distro.hcl -- root manifest for this Zenith Linux build.
# Read by `zlb` for every command. See `zlb manifest --help` for the
# full block reference.

distro {
  name     = "Zenith Linux"
  codename = "nova"
  version  = "0.1.0"

  # "self" = this build bootstraps from a previously built Zenith seed
  # (see out/cache/seeds/). Point at another distro name/tarball URL
  # once you need a foreign bootstrap instead.
  base = "self"

  arch = ["x86_64", "aarch64"]
}

modules {
  # names correspond to modules/<name>/ directories. Leave empty/omit
  # to auto-include every directory under modules/.
  include = ["core"]
}

iso {
  bootloader  = "grub"
  boot_mode   = "hybrid"
  compression = "xz"
  output      = "zenith-linux-${version}-${arch}.iso"
}

oci {
  registry   = "ghcr.io/zenith-linux"
  repository = "zenith-linux"
  tag        = "${version}"
  output     = "zenith-linux-${version}-${arch}-oci"
}

keys {
  gpg_key      = "keys/zenith-release.asc"
  gpg_key_id   = ""
  zpm_key_list = "keys/default.hcl"
}

workflow {
  provider    = "github"
  triggers    = ["push", "tag"]
  matrix_arch = ["x86_64", "aarch64"]
}
"""

const packageListTemplate = """
# modules/core/package.list
# One zpm package name per line. Blank lines and lines starting with
# # are ignored. This is a placeholder list until zpm is fully
# implemented -- `zlb build rootfs` will log what it *would* install.

base
linux
zenith-init
zpm
"""

const packageRemoveTemplate = """
# modules/core/package.remove
# Packages to strip out after installation (e.g. build-only deps
# pulled in transitively). One package name per line.
"""

const janetHookTemplate = """
# modules/core/scripts/10-hostname.janet
#
# Runs inside the ZLB build with build context in env vars:
#   ZLB_ROOTFS, ZLB_STAGE, ZLB_MODULE, ZLB_ARCH,
#   ZLB_DISTRO_NAME, ZLB_VERSION
#
# ZLB_STAGE is one of: pre-packages | post-packages | post-overlay
# Scripts run at every stage -- check ZLB_STAGE and no-op otherwise.

(def stage (os/getenv "ZLB_STAGE"))
(def rootfs (os/getenv "ZLB_ROOTFS"))

(when (= stage "post-overlay")
  (print "[core] writing /etc/hostname into " rootfs)
  (spit (string rootfs "/etc/hostname") "zenith\n"))
"""

const defaultKeysHcl = """
# keys/default.hcl -- zpm trust store.
# Every repo the base install pulls from must be declared here with a
# key_id and a pubkey path so zpm can verify signatures before install.

repo "core" {
  url    = "https://pkg.zenithlinux.org/core"
  key_id = "0xPLACEHOLDER"
  pubkey = "keys/zpm/core.asc"
}
"""

const readmeTemplate = """
# {distroName}

Built with ZLB (Zenith Linux Builder).

```sh
zlb build rootfs --arch x86_64
zlb build iso    --arch x86_64
zlb build oci    --arch x86_64
```

Artifacts land in `out/`. Everything under `out/cache/` is reusable
build state -- safe to delete, never shipped.
"""

proc writeIfMissing(path, content: string) =
  if fileExists(path):
    echo "  ~ skipped (exists): " & path
    return
  createDir(parentDir(path))
  writeFile(path, content)
  echo "  + " & path

proc scaffoldProject*(dir: string) =
  createDir(dir)

  writeIfMissing(dir / "distro.hcl", distroHclTemplate)

  writeIfMissing(dir / "modules" / "core" / "package.list", packageListTemplate)
  writeIfMissing(dir / "modules" / "core" / "package.remove", packageRemoveTemplate)
  writeIfMissing(dir / "modules" / "core" / "scripts" / "10-hostname.janet", janetHookTemplate)

  createDir(dir / "overlays" / "branding")
  createDir(dir / "overlays" / "home")
  createDir(dir / "overlays" / "system" / "etc")
  writeIfMissing(dir / "overlays" / "branding" / ".gitkeep", "")
  writeIfMissing(dir / "overlays" / "home" / ".gitkeep", "")
  writeIfMissing(dir / "overlays" / "system" / "etc" / "zenith-release",
    "Zenith Linux (see /distro.hcl in the build repo for the source of truth)\n")

  writeIfMissing(dir / "keys" / "default.hcl", defaultKeysHcl)
  createDir(dir / "keys" / "zpm")

  createDir(dir / "out" / "cache")
  writeIfMissing(dir / "out" / ".gitignore", "*\n!.gitignore\n!cache/.gitignore\n")
  writeIfMissing(dir / "out" / "cache" / ".gitignore", "*\n!.gitignore\n")

  writeIfMissing(dir / "README.md", readmeTemplate.replace("{distroName}", "Zenith Linux"))

  echo ""
  echo "Zenith Linux project scaffolded in '" & dir & "'."
  echo "Next: cd " & dir & " && zlb build rootfs --arch x86_64"
