# ZLB -- Zenith Linux Builder

ZLB is the build tool for **Zenith Linux**: it turns a `distro.hcl`
manifest plus a `modules/` / `overlays/` / `keys/` tree into bootable
ISO images and OCI (container) images, with cross-architecture builds
and generated CI workflows.

Written entirely in [Nim](https://nim-lang.org/).

## Install

```sh
nimble install   # or: nim c -d:release -o:bin/zlb src/zlb.nim
```

Requires on PATH (only when actually building, not for `zlb init`):
`tar`, `mksquashfs` (squashfs-tools), `grub-mkrescue` or `xorriso`,
`gpg` (optional, for release signing), `janet` (for module hook
scripts), and `qemu-user-static` binaries when cross-building.

## Quick start

```sh
zlb init my-distro
cd my-distro
zlb build rootfs --arch x86_64
zlb build iso    --arch x86_64
zlb build oci    --arch x86_64
zlb ci generate
```

Final artifacts land in `out/`. Everything under `out/cache/` is
reusable build state (staged rootfs, seeds, scratch work) -- safe to
delete, never shipped, and cached by the generated CI workflow.

## Project layout

```
distro.hcl                 root manifest (see below)

modules/
  <name>/
    package.list            zpm packages to install (placeholder until
    package.remove           zpm itself is finished -- see zlbpkg/zpm.nim)
    scripts/
      NN-*.janet             .janet ONLY -- run at pre-packages,
                              post-packages, and post-overlay stages

overlays/
  branding/                 installer wallpapers/banners, staged
                              alongside the ISO, not into the rootfs
  home/                     -> rootfs /etc/skel
  system/                   -> rootfs / (verbatim)

keys/
  default.hcl                zpm trust store (repo "name" { url, key_id, pubkey })
  zenith-release.asc         GPG key used to sign SHA256SUMS

out/                        FINAL images only
out/cache/                  reusable build state (rootfs, seeds, scratch)
```

## `distro.hcl`

```hcl
distro {
  name     = "Zenith Linux"
  codename = "nova"
  version  = "0.1.0"
  base     = "self"                    # bootstraps from a Zenith seed
  arch     = ["x86_64", "aarch64"]
}

modules {
  include = ["core"]                   # modules/core/
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
}

keys {
  gpg_key      = "keys/zenith-release.asc"
  zpm_key_list = "keys/default.hcl"
}

workflow {
  provider    = "github"               # or "gitlab"
  matrix_arch = ["x86_64", "aarch64"]
}
```

`zlb` ships a small dependency-free parser for this subset of HCL2
(`src/zlbpkg/hcl.nim`) -- blocks, labeled blocks, strings, numbers,
bools, and lists. No expressions/functions/for-loops; that's
intentional, manifests stay easy to diff and hand-edit.

## Self-hosted bootstrap

`distro.base = "self"` means a given arch's build bootstraps from a
Zenith rootfs tarball *previously built by ZLB itself*
(`out/cache/seeds/<arch>-<version>.tar.zst`). The very first build for
a fresh arch has no seed yet, so ZLB falls back to a minimal empty
skeleton and lets the module pipeline (zpm + janet hooks) populate it
-- once you publish a seed tarball into `out/cache/seeds/`, later
builds (and CI, via the cached `out/cache/`) bootstrap from it
directly.

## Cross-compilation

Building `aarch64` on an `x86_64` host (or vice versa) is done via
`qemu-user-static` + binfmt_misc: ZLB copies the matching static QEMU
interpreter into the staged rootfs's `/usr/bin` so package installs
and `.janet` hooks run as if natively on the target (`zlbpkg/crosscompile.nim`).
Nothing extra needed in `distro.hcl` beyond listing the arch.

## zpm (placeholder)

`zpm`, Zenith's own package manager, isn't finished yet. Every call
in `zlbpkg/zpm.nim` shells out to a real `zpm` binary if one is found
on PATH; otherwise it logs exactly what it *would* run and continues,
so `zlb build` stays fully exercisable end-to-end today. Swapping in
the real implementation later touches nothing else in ZLB.

## CI/CD

`zlb ci generate` reads the `workflow { }` block and writes a ready
GitHub Actions matrix build (`.github/workflows/build.yml`) or GitLab
CI pipeline (`.gitlab-ci.yml`) that installs build deps, restores
`out/cache/`, runs `zlb build rootfs/iso/oci` per arch, and uploads
`out/*.iso` + `out/oci/**` as artifacts.

## Source layout

```
src/zlb.nim                  CLI entry point
src/zlbpkg/types.nim          shared types (incl. the HCL AST)
src/zlbpkg/hcl.nim            HCL2-subset lexer/parser
src/zlbpkg/manifest.nim       distro.hcl -> Manifest
src/zlbpkg/paths.nim          out/ + out/cache/ layout
src/zlbpkg/modules.nim        modules/<name>/ discovery
src/zlbpkg/overlay.nim        overlays/{system,home,branding} application
src/zlbpkg/zpm.nim            zpm wrapper (placeholder)
src/zlbpkg/janetrunner.nim    runs modules/*/scripts/*.janet hooks
src/zlbpkg/keys.nim           GPG signing + zpm trust store
src/zlbpkg/crosscompile.nim   arch/triple resolution, qemu-user setup
src/zlbpkg/rootfs.nim         orchestrates `zlb build rootfs`
src/zlbpkg/iso.nim            squashfs + grub-mkrescue -> ISO
src/zlbpkg/oci.nim            manual OCI Image Layout writer
src/zlbpkg/ci.nim             GitHub Actions / GitLab CI generator
src/zlbpkg/scaffold.nim       `zlb init`
```

## License

GPL-3.0
