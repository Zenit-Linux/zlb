# ZLB -- Zenit Linux Builder

ZLB is the build tool for **Zenit Linux**: it turns a `distro.hcl`
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
  zenit-release.asc         GPG key used to sign SHA256SUMS

out/                        FINAL images only
out/cache/                  reusable build state (rootfs, seeds, scratch)
```

## `distro.hcl`

```hcl
distro {
  name     = "Zenit Linux"
  codename = "nova"
  version  = "0.1.0"
  base     = "self"                    # bootstraps from a Zenit seed
  arch     = ["x86_64", "aarch64"]
}

modules {
  include = ["core"]                   # modules/core/
}

iso {
  bootloader  = "grub"
  boot_mode   = "hybrid"
  compression = "xz"
  output      = "zenit-linux-${version}-${arch}.iso"
}

oci {
  registry   = "ghcr.io/zenit-linux"
  repository = "zenit-linux"
  tag        = "${version}"
}

keys {
  gpg_key      = "keys/zenit-release.asc"
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

## `package.list` format

Each `modules/<name>/package.list` lists what to install for that module,
via `zpm` (`package.remove` uses the identical syntax, for removals).

```hcl
package "curl" {}                       # bare name -> backend = apt (host default)

package "network-manager" {
  backend     = "apt"
  description = "human-readable note, shown in build summaries only"
}

package "grub-pc" {
  backend = "apt"
  arch    = "x86_64"                    # comma-separated list, e.g. "x86_64,aarch64"
}                                        # bare packages (no "arch") apply to EVERY arch

package "grub-efi-arm64" {
  backend = "apt"
  arch    = "aarch64"
}

package "kernel" {
  backend = "own"
  variant = "stable"                    # backend="own" -> branch/system variant
  version = "2024.10"                   # backend="own" ONLY -- pins the exact release
}                                        # tag substituted for "{version}" in the tool's
                                         # "bin" URL (own-repository.json), so `zpm` never
                                         # has to ask GitHub "what's latest" for this one
```

Fields:
- **`backend`** -- `apt`, `dnf`, `pacman`, `zypper`, `brew`, `flatpak`, `snap`,
  `cargo`, `npm`, `pip`, or `own` (Zenit's own tool ecosystem, see
  `custom/own-repository.json`). Defaults to whatever `zpm` picks as the
  host's native package manager if omitted.
- **`variant`** -- requires `backend` to be set explicitly. Meaning
  depends on the backend: for `own`, it's a branch/system name (see
  `zpm own systems`); for everything else, it's currently unused.
- **`arch`** -- comma-separated list of architectures this package
  applies to (matches whatever `distro.arch` uses, e.g. `x86_64`,
  `aarch64`). Omit it (or leave empty) to apply to every architecture,
  which is the default and matches all prior behavior. Packages outside
  the current build's `--arch` are silently skipped (logged at build
  time) -- this exists because some packages have a **different real
  name per architecture** (`grub-efi-amd64` vs `grub-efi-arm64`; there's
  no single apt package name that works on both).
- **`version`** -- **only** valid together with `backend = "own"`.
  Pins an exact release tag, substituted for `{version}` in that tool's
  `bin` URL in `own-repository.json`. Without it, `zpm` resolves
  "latest" itself (redirect → centralized manifest → REST API, in that
  order of preference -- see `zpm`(1) § OPTYMALIZACJA ZAPYTAŃ API for
  why that matters at scale). Using any other backend with `version` set
  is a manifest error (`zlb` refuses to build) -- apt/dnf/pacman/zypper
  have their own, different version-pinning syntax, not handled by this
  field yet.
- **`description`** -- free text, purely informational.



`distro.base = "self"` means a given arch's build bootstraps from a
Zenit rootfs tarball *previously built by ZLB itself*
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

## zpm

`zpm`, Zenit's own package manager, is the real backend `zlb` shells out
to for every package install/remove during a build (`zlbpkg/zpm.nim`
serializes each `package.list` entry to the compact `name -> backend ->
variant` syntax `zpm` parses -- see `parsePackageSpec` in `zpm`'s
`orchestrator.nim`/`building.nim`). If `zpm` isn't found on `PATH` (and
`zlb` can't fetch one itself), the build fails hard by default rather
than silently producing an image with nothing actually installed --
pass `--allow-placeholder` only if that's genuinely what you want (e.g.
smoke-testing the pipeline itself). See `zpm`(1) for how to obtain a
real `zpm` (release binary, a pinned version, or building it from
source).

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
