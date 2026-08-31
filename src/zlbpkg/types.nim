import std/tables
export tables
## `HclValue`/`HclKind` (razem z polami wariantowymi hkString/hkNumber/
## hkBool/hkList/hkBlock) NIE są już zdefiniowane w tym pliku -- pochodzą
## z cienkiej nakładki `./hclcore.nim` na wspólną bibliotekę `hcl-nim`
## (paczka nimble `hcl_nim`, patrz `hclcore.nim` po pełne wyjaśnienie i
## dlaczego ta nakładka NIE mogła się dalej nazywać `hclnim.nim`).
## Re-eksportowane tutaj, żeby `Manifest.raw: Table[string, HclValue]`
## niżej i reszta zlb (manifest.nim, modules.nim, keys.nim,
## installerconfig.nim) mogły dalej pisać po prostu `HclValue`/`hkBlock`/
## ... bez importowania `hclcore` osobno.
import ./hclcore
export hclcore.HclValue, hclcore.HclKind

type
  ZlbError* = object of CatchableError
    ## Raised on any recoverable build error. Caught at the CLI boundary
    ## and printed nicely instead of a raw stacktrace.

  Arch* = enum
    ## Rozszerzona lista architektur -- x86_64/aarch64/riscv64 to
    ## architektury "z pierwszej klasy" (mają qemu-user + triple), reszta
    ## jest wspierana na tyle, na ile pozwala toolchain hosta (przydatne
    ## przy budowaniu OCI-only obrazów bez pełnego ISO/bootloadera).
    archX86_64  = "x86_64"
    archAarch64 = "aarch64"
    archRiscv64 = "riscv64"
    archArmv7   = "armv7"
    archArmhf   = "armhf"
    archI686    = "i686"
    archPpc64le = "ppc64le"
    archS390x   = "s390x"
    archLoong64 = "loongarch64"
    archSelf    = "self"       ## build for the arch ZLB itself is running on

  BootMode* = enum
    bmBios = "bios"
    bmUefi = "uefi"
    bmHybrid = "hybrid"

  ImageKind* = enum
    ikIso = "iso"
    ikOci = "oci"

  ## ---- distro.hcl model -------------------------------------------------

  DistroInfo* = object
    name*: string
    codename*: string
    version*: string
    base*: string             ## "self" => distro bootstraps from itself,
                               ## otherwise a foreign base like "fedora",
                               ## "debian", "arch", "opensuse", "alpine" --
                               ## used to pick a sane default_backend below.
    defaultBackend*: string   ## explicit override for distro.default_backend;
                               ## "" => derived from `base` (see zpm.nim's
                               ## backendForBase()).
    arches*: seq[Arch]

  IsoConfig* = object
    bootloader*: string       ## "grub", "limine", ...
    bootMode*: BootMode
    compression*: string      ## "xz", "gzip", "none"
    output*: string           ## output filename template

  OciConfig* = object
    registry*: string
    repository*: string
    tag*: string
    output*: string

  KeysConfig* = object
    gpgKey*: string
    gpgKeyId*: string
    zpmKeyList*: string       ## points at keys/default.hcl

  WorkflowConfig* = object
    provider*: string         ## "github", "gitlab"
    triggers*: seq[string]
    matrixArches*: seq[Arch]

  ModulesConfig* = object
    includeMods*: seq[string]    ## names of modules/<name> dirs to include

  Manifest* = object
    raw*: Table[string, HclValue]
    distro*: DistroInfo
    modules*: ModulesConfig
    iso*: IsoConfig
    oci*: OciConfig
    keys*: KeysConfig
    workflow*: WorkflowConfig
    toolset*: ToolsetConfig

  ## ---- toolset (GNU coreutils vs. własne narzędzia Zenit) ----------------

  ToolsetProfile* = enum
    ## Które narzędzia bazowe (odpowiedniki coreutils/dopasowane 1:1 do
    ## krótkich nazw w zenit-base/tools/) trafiają do obrazu. Patrz
    ## `zenit-base/tools/README.md` -- każde narzędzie tam (wm, rm, un,
    ## pm, ro, zb, ni, en, xa, so, sz, pf, lb, up, wp, pr, fr, cr, sp, id,
    ## hn, zdb, kt, dl, df, gr, echo, kp, mk, wz, zn, about, ar, ow, du)
    ## odpowiada jednemu klasycznemu narzędziu GNU -- profil decyduje,
    ## KTÓRA implementacja tego zestawu trafia do obrazu, nie czy w ogóle.
    tpGnu   = "gnu"     ## klasyczny GNU coreutils/util-linux/... (backend apt)
    tpZenit = "zenit"   ## własne, minimalne narzędzia Zenit (backend own)

  ToolsetConfig* = object
    profile*: ToolsetProfile      ## domyślny profil z distro.hcl (blok toolset {})
    allowOverride*: bool           ## czy `zlb build --toolset=...` może nadpisać profil
    gnuModule*: string              ## nazwa modułu z package.list dla profilu gnu
    zenitModule*: string             ## nazwa modułu z package.list dla profilu zenit

  ## ---- module system ------------------------------------------------------

  PackageEntry* = object
    ## Jeden wpis z package.list / package.remove (format HCL od v0.3,
    ## patrz zlbpkg/modules.nim). Bloki `package "nazwa" { ... }`:
    ##   package "systemd" { backend = "apt" }
    ##   package "kernel"  { backend = "own" variant = "testing" description = "jądro" }
    ##   package "git"     { backend = "apt" variant = "debian.testing" }
    name*: string
    backend*: string          ## "" = domyślny backend dystrybucji
    variant*: string          ## v0.3: "" = domyślny. Dla backend="own" -- branch
                               ## (stable/rolling/semi-rolling/testing/...) z
                               ## own-repository.json. Dla backendów hosta -- docelowa
                               ## dystrybucja, opcjonalnie ".suita" (np. "debian.testing") --
                               ## instalowana BEZPIECZNIE w izolacji (patrz zpm/crossdistro.nim),
                               ## nigdy przez bezpośrednie dopisanie repo do hosta.
    description*: string      ## v0.3: czysto informacyjny opis (dokumentacja modułu,
                               ## wyświetlany w podsumowaniach builda) -- nieużywany do logiki

  ModulePackages* = object
    name*: string
    installList*: seq[PackageEntry]  ## from package.list
    removeList*: seq[PackageEntry]   ## from package.remove
    janetScripts*: seq[string]       ## absolute paths to modules/<name>/scripts/*.janet

  ## ---- overlay system -------------------------------------------------

  OverlayPaths* = object
    brandingDir*: string
    homeDir*: string
    systemDir*: string

  ## ---- installer/ ----------------------------------------------------------
  ## v0.4: przestało być placeholderem -- zlb zna teraz źródło Zenit
  ## Installer (repo `installer`) i faktycznie EMBEDUJE tę konfigurację
  ## (oraz pliki brandingu, które wskazuje) do rootfs pod
  ## `/etc/zenit/installer/config.hcl` i `/usr/share/zenit/branding/`
  ## (patrz `embedInstallerConfig` w tym module i wywołanie z
  ## rootfs.nim). Instalator czyta ten sam plik w trakcie działania
  ## (patrz `installerpkg/config.nim` w repo `installer`) tym samym
  ## parserem `hcl-nim` -- więc wybór środowisk/lokalizacji faktycznie
  ## dociera do kreatora, zamiast być tylko udokumentowaną konwencją.

  InstallerConfig* = object
    present*: bool                  ## czy installer/config.hcl w ogóle istnieje w projekcie
    desktopSelector*: bool          ## pokazywać ekran wyboru środowiska graficznego
    desktops*: seq[string]          ## dostępne DE/WM -- każdy (poza "none") MUSI mieć
                                     ## odpowiadający katalog modules/desktop-<id>/
                                     ## (patrz validateInstallerBranding/validateDesktops)
    defaultDesktop*: string
    defaultLocale*: string
    locales*: seq[string]
    allowManualPartitioning*: bool
    title*: string                   ## nazwa produktu pokazywana w kreatorze
                                       ## (installer.title w config.hcl); puste = użyj distro.name
    brandingIcon*: string            ## nazwa pliku WZGLĘDEM overlays/branding/ (nie ścieżka
                                      ## absolutna -- overlays/branding/ to źródło prawdy dla
                                      ## SAMYCH plików, installer/config.hcl tylko WYBIERA które
                                      ## z nich użyć)
    brandingBanner*: string

const
  InstallerEmbeddedConfigPath* = "etc/zenit/installer/config.hcl"
    ## Ścieżka WZGLĘDEM roota rootfs (bez wiodącego '/') pod którą
    ## `embedInstallerConfig` kopiuje `installer/config.hcl` -- ta sama
    ## ścieżka (z wiodącym '/') jest wpisana na stałe w
    ## `installerpkg/config.nim` w repo `installer`. Zmiana tej stałej w
    ## jednym repo bez drugiego to rozjazd -- stąd nazwa eksportowana, nie
    ## zakopana w ciele funkcji.
  InstallerEmbeddedBrandingDir* = "usr/share/zenit/branding"
    ## Jw., dla plików wskazanych przez branding.icon/branding.banner.
