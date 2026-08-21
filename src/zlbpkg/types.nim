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
    ## tools { } -- narzędzia ekosystemu Zenith pobierane automatycznie na
    ## starcie budowania (patrz zlbpkg/tools.nim), zamiast zakładać, że są
    ## już zainstalowane na maszynie budującej / w CI.
    autoFetch*: bool          ## czy w ogóle bootstrapować (domyślnie true)
    zpmUrl*: string           ## dosłowny URL do binarki zpm
    installerUrl*: string     ## dosłowny URL do binarki Zenith Installer
    cacheDir*: string         ## gdzie trzymać pobrane binarki (out/cache/tools domyślnie)

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
    ## Jeden wpis z package.list / package.remove. Obsługuje zarówno
    ## zwykłe nazwy ("systemd") jak i jawne wymuszenie backendu zpm
    ## ("systemd -> apt") -- patrz zlbpkg/modules.nim.
    name*: string
    backend*: string          ## "" = domyślny backend dystrybucji

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
