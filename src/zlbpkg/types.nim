import std/tables
export tables

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

  ToolsConfig* = object
    ## tools { } -- narzędzia ekosystemu Zenit pobierane automatycznie na
    ## starcie budowania (patrz zlbpkg/tools.nim), zamiast zakładać, że są
    ## już zainstalowane na maszynie budującej / w CI.
    autoFetch*: bool          ## czy w ogóle bootstrapować (domyślnie true)
    zpmUrl*: string           ## dosłowny URL do binarki zpm
    installerUrl*: string     ## dosłowny URL do binarki Zenit Installer
    cacheDir*: string         ## gdzie trzymać pobrane binarki (out/cache/tools domyślnie)
    allowPlaceholder*: bool   ## v0.2 -- domyślnie FALSE. Gdy 'zpm' nie jest dostępne (ani w
                              ## cache'u, ani na PATH, ani do pobrania), zlbpkg/zpm.nim
                              ## domyślnie TWARDO PRZERYWA build zamiast (jak w v0.1) po
                              ## cichu symulować sukces. Ustaw `allow_placeholder = true`
                              ## w distro.hcl (blok tools {}), żeby świadomie wrócić do
                              ## starego zachowania (np. do inspekcji drzewa modułów bez
                              ## realnego zpm) -- z jawnym, głośnym ostrzeżeniem przy KAŻDYM
                              ## użyciu, nie cichym "would run: zpm ...".

  Manifest* = object
    raw*: Table[string, HclValue]
    distro*: DistroInfo
    modules*: ModulesConfig
    iso*: IsoConfig
    oci*: OciConfig
    keys*: KeysConfig
    workflow*: WorkflowConfig
    tools*: ToolsConfig

  ## ---- minimal HCL AST ---------------------------------------------------

  HclKind* = enum
    hkString, hkNumber, hkBool, hkList, hkBlock

  HclValue* = ref object
    case kind*: HclKind
    of hkString: strVal*: string
    of hkNumber: numVal*: float
    of hkBool:   boolVal*: bool
    of hkList:   listVal*: seq[HclValue]
    of hkBlock:  fields*: OrderedTableRef[string, HclValue]

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

  ## ---- installer/ (v0.3 -- PLACEHOLDER, patrz zlbpkg/installerconfig.nim) --

  InstallerConfig* = object
    ## Sparsowana zawartość installer/config.hcl. PLACEHOLDER: zlb nie zna
    ## jeszcze wewnętrznego kodu źródłowego Zenit Installer -- ten typ i
    ## jego parser to wstępny kontrakt, rozbudowywany razem z faktyczną
    ## integracją zlb<->installer, gdy repo instalatora będzie dostępne
    ## do wglądu. Pola poniżej to NAJBARDZIEJ prawdopodobne opcje na
    ## podstawie tego, co już wiadomo (wybór środowiska graficznego,
    ## lokalizacja, branding) -- traktuj jako punkt wyjścia, nie kontrakt
    ## ostateczny.
    present*: bool                  ## czy installer/config.hcl w ogóle istnieje w projekcie
    desktopSelector*: bool          ## pokazywać ekran wyboru środowiska graficznego
    desktops*: seq[string]          ## dostępne DE/WM (każdy MUSI mieć wpis w package.list)
    defaultDesktop*: string
    defaultLocale*: string
    locales*: seq[string]
    allowManualPartitioning*: bool
    brandingIcon*: string           ## nazwa pliku WZGLĘDEM overlays/branding/ (nie ścieżka
                                     ## absolutna -- overlays/branding/ to źródło prawdy dla
                                     ## SAMYCH plików, installer/config.hcl tylko WYBIERA które
                                     ## z nich użyć, zgodnie z tym, co ustalono: "uzytkownik tez
                                     ## decyduje w distro.hcl i installer.hcl")
    brandingBanner*: string
