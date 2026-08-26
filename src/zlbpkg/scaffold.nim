import std/[os, strutils]
import ./types

const distroHclTemplate = """
# distro.hcl -- root manifest for this Zenit Linux build.
# Read by `zlb` for every command. See `zlb manifest --help` for the
# full block reference.

distro {
  name     = "Zenit Linux"
  codename = "nova"
  version  = "0.1.0"

  # "self" = this build bootstraps from a previously built Zenit seed
  # (see out/cache/seeds/). Point at a foreign distro name ("fedora",
  # "debian", "arch", "opensuse", "alpine", ...) once you need a foreign
  # bootstrap instead -- it also picks the default zpm backend used for
  # any package.list entry that doesn't set 'backend' explicitly
  # (fedora -> dnf, debian -> apt, arch -> pacman, ...). Override that
  # derived choice explicitly with default_backend below.
  base = "self"
  # default_backend = "apt"

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
  output      = "zenit-linux-${version}-${arch}.iso"
}

oci {
  registry   = "ghcr.io/zenit-linux"
  repository = "zenit-linux"
  tag        = "${version}"
  output     = "zenit-linux-${version}-${arch}-oci"
}

keys {
  gpg_key      = "keys/zenit-release.asc"
  gpg_key_id   = ""
  zpm_key_list = "keys/default.hcl"
}

workflow {
  provider    = "github"
  triggers    = ["push", "tag"]
  matrix_arch = ["x86_64", "aarch64"]
}

tools {
  # Pobierane automatycznie na starcie `zlb build ...` do out/cache/tools/
  # (patrz zlbpkg/tools.nim) -- to jest oficjalna alternatywa dla ręcznego
  # `curl -fsSL ... | sh` przy bootstrapowaniu zpm/instalatora w CI.
  auto_fetch    = true
  zpm_url       = "https://github.com/Zenit-Linux/zpm/releases/download/v0.1/zpm"
  installer_url = "https://github.com/Zenit-Linux/installer/releases/download/v0.1/installer"
}
"""

const packageListTemplate = """
# modules/core/package.list -- format HCL (v0.3).
#
# Jeden blok `package "nazwa" { ... }` na pakiet. Pusty blok `{}` (albo
# pominięcie pól) = wszystko domyślne: backend wybierany na podstawie
# distro.base / distro.default_backend (patrz distro.hcl,
# zlbpkg/manifest.nim::backendForBase).
#
# Pola dostępne w bloku `package`:
#   backend       -- wymusza konkretny backend zpm dla TEGO pakietu:
#                     apt, dnf, pacman, zypper, flatpak, snap, brew,
#                     cargo, pip, npm, own.
#   variant       -- WYMAGA jawnie podanego 'backend'. Znaczenie zależy
#                     od backendu:
#                       backend = "own"  -> nazwa BRANCHA z pola
#                         "branches" w own-repository.json (schema_version
#                         2), np. "stable" / "rolling" / "semi-rolling" /
#                         "testing" -- albo dowolna nazwa, którą zdefiniuje
#                         supasujące narzędzie.
#                       backend = apt/dnf/pacman/zypper/... -> docelowa
#                         DYSTRYBUCJA, opcjonalnie z ".suitą", np.
#                         "debian" albo "debian.testing". Instalowane
#                         BEZPIECZNIE, w izolowanym kontenerze (patrz
#                         zpm/crossdistro.nim) -- NIGDY przez dopisanie
#                         obcego repo do bazy pakietów hosta.
#   description   -- czysto informacyjny opis (dokumentacja modułu,
#                     wyświetlany w podsumowaniach builda).
#
# --- system bazowy (backend domyślny wg distro.hcl) ---
package "base" {}
package "linux-firmware" {}

# --- ekosystem Zenit, zawsze przez "own" (bez curl) ---
package "zpm" {
  backend     = "own"
  description = "Zenit Package Manager -- wbudowany, domyślny"
}
package "installer" {
  backend = "own"
}
package "kernel" {
  backend     = "own"
  variant     = "stable"
  description = "domyślne jądro Linux (branch: stable)"
}
package "zsrv" {
  backend     = "own"
  description = "domyślny init system Zenit"
}
package "zboot" {
  backend     = "own"
  description = "domyślny bootloader Zenit"
}

# --- narzędzia systemowe z jawnie wybranych backendów ---
package "systemd" {
  backend = "apt"
}
package "networkmanager" {
  backend = "apt"
}
package "grub" {
  backend = "apt"
}
package "efibootmgr" {
  backend = "apt"
}

# --- narzędzia dodatkowe ---
package "htop" {
  backend = "apt"
}
package "neovim" {
  backend = "apt"
}
package "git" {
  backend = "apt"
  # przykład instalacji cross-distro: pobierz z Debiana testing zamiast
  # z natywnych repo hosta (patrz zpm/crossdistro.nim)
  # variant = "debian.testing"
}
package "ripgrep" {
  backend = "cargo"
}
package "firefox" {
  backend = "flatpak"
}

# --- pakiet bez żadnych opcji: backend/wariant wzięte z domyślnej
#     dystrybucji/brancha zadeklarowanej w distro.hcl ---
package "curl" {}
"""

const packageRemoveTemplate = """
# modules/core/package.remove -- ta sama gramatyka HCL co package.list.
# Pakiety do usunięcia po instalacji (np. zależności potrzebne tylko do
# budowania, dociągnięte tranzytywnie). Pola 'variant'/'description' są
# tu dopuszczalne, ale bez znaczenia (usuwanie nie rozróżnia branchy).
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
  (spit (string rootfs "/etc/hostname") "zenit\n"))
"""

const defaultKeysHcl = """
# keys/default.hcl -- zpm trust store.
# Every repo the base install pulls from must be declared here with a
# key_id and a pubkey path so zpm can verify signatures before install.

repo "core" {
  url    = "https://pkg.zenitlinux.org/core"
  key_id = "0xPLACEHOLDER"
  pubkey = "keys/zpm/core.asc"
}
"""

const readmeTemplate = """
# {distroName}

Built with ZLB (Zenit Linux Builder).

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

const installerConfigTemplate = """
# installer/config.hcl -- konfiguracja Zenit Installer (PLACEHOLDER v0.3).
#
# UWAGA: zlb jeszcze nie zna wewnętrznego kodu źródłowego instalatora --
# ten plik to szkielet/kontrakt wstępny (zlbpkg/installerconfig.nim),
# rozbudowywany razem z faktyczną integracją zlb<->installer, gdy repo
# instalatora będzie dostępne. Katalog installer/ jest OPCJONALNY --
# usuń go, jeśli budujesz obraz bez instalatora (np. kontener serwerowy).

installer {
  # Pokazywać ekran wyboru środowiska graficznego, jeśli obraz zawiera
  # więcej niż jedno DE/WM.
  desktop_selector = true

  # Dostępne do wyboru -- każdy MUSI mieć odpowiadający wpis w
  # modules/*/package.list (dowolny backend).
  desktops = ["gnome", "kde", "none"]
  default_desktop = "gnome"

  default_locale = "en_US.UTF-8"
  locales         = ["en_US.UTF-8", "pl_PL.UTF-8"]

  allow_manual_partitioning = true
}

branding {
  # Nazwy plików WZGLĘDEM overlays/branding/ w tym repo -- overlays/branding/
  # to źródło prawdy dla SAMYCH obrazów (distro.hcl), ten blok tylko
  # WYBIERA które z dostarczonych plików ma pokazać instalator.
  icon   = "icon-no-bg.png"
  banner = "banner.png"
}
"""

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
  writeIfMissing(dir / "overlays" / "system" / "etc" / "zenit-release",
    "Zenit Linux (see /distro.hcl in the build repo for the source of truth)\n")

  writeIfMissing(dir / "keys" / "default.hcl", defaultKeysHcl)
  createDir(dir / "keys" / "zpm")

  createDir(dir / "installer")
  writeIfMissing(dir / "installer" / "config.hcl", installerConfigTemplate)

  createDir(dir / "out" / "cache")
  writeIfMissing(dir / "out" / ".gitignore", "*\n!.gitignore\n!cache/.gitignore\n")
  writeIfMissing(dir / "out" / "cache" / ".gitignore", "*\n!.gitignore\n")

  writeIfMissing(dir / "README.md", readmeTemplate.replace("{distroName}", "Zenit Linux"))

  echo ""
  echo "Zenit Linux project scaffolded in '" & dir & "'."
  echo "Next: cd " & dir & " && zlb build rootfs --arch x86_64"
