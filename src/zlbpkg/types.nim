import std/tables
export tables

type
  ZlbError* = object of CatchableError
    ## Raised on any recoverable build error. Caught at the CLI boundary
    ## and printed nicely instead of a raw stacktrace.

  Arch* = enum
    archX86_64  = "x86_64"
    archAarch64 = "aarch64"
    archRiscv64 = "riscv64"
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
    base*: string             ## "self" => distro bootstraps from itself
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

  ModulePackages* = object
    name*: string
    installList*: seq[string]     ## from package.list
    removeList*: seq[string]      ## from package.remove
    janetScripts*: seq[string]    ## absolute paths to modules/<name>/scripts/*.janet

  ## ---- overlay system -------------------------------------------------

  OverlayPaths* = object
    brandingDir*: string
    homeDir*: string
    systemDir*: string
