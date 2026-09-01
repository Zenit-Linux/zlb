import std/[unittest, os, tempfiles, strutils]
import ../src/zlbpkg/hcl
import ../src/zlbpkg/manifest
import ../src/zlbpkg/types
import ../src/zlbpkg/modules
import ../src/zlbpkg/installerconfig
import ../src/zlbpkg/tools

## v0.2 -- zamyka lukę "Brak testów jednostkowych dla hcl.nim/manifest.nim
## w zlb". Uruchamiane przez `nimble test`.
##
## v0.4: `zlbpkg/hcl.nim` deleguje teraz parsowanie do wspólnej biblioteki
## hcl-nim (patrz `zlbpkg/hclnim.nim`) -- te testy więc w praktyce ćwiczą
## hcl-nim POPRZEZ cienką nakładkę zlb (import, re-export, `ZlbError`
## zamiast `hclnim.HclError`). Osobne testy samego hcl-nim (bez adaptera)
## żyją w repo hcl-nim, `tests/test_hclnim.nim`.

suite "hcl (zlb -- przez wspólną bibliotekę hcl-nim)":
  test "parsuje blok distro":
    let root = parseHcl("""
      distro {
        name = "Zenit Linux"
        codename = "testcodename"
        version = "0.2.0"
        arch = ["x86_64", "aarch64"]
      }
    """)
    let d = root.getBlock("distro")
    check d != nil
    check d.getStr("name") == "Zenit Linux"
    check d.getStrList("arch") == @["x86_64", "aarch64"]

  test "bloki z etykietą (module \"nazwa\" { ... })":
    let root = parseHcl("""
      module "base" {
        enabled = true
      }
    """)
    let m = root.getBlock("module")
    check m != nil
    check m.label() == "base"
    check m.getBool("enabled") == true

  test "powtórzone klucze bloków zwijają się w listę":
    let root = parseHcl("""
      module "a" { enabled = true }
      module "b" { enabled = false }
    """)
    let m = root.getBlock("module")
    check m != nil
    check m.kind == hkList
    check m.listVal.len == 2

  test "błędna składnia rzuca ZlbError, nie crashuje":
    expect(ZlbError):
      discard parseHcl("distro { name = }")

suite "manifest (loadManifest)":
  test "ładuje minimalny poprawny distro.hcl":
    let dir = createTempDir("zlbtest", "")
    defer: removeDir(dir)
    let path = dir / "distro.hcl"
    writeFile(path, """
      distro {
        name = "Zenit Linux"
        codename = "test"
        version = "0.2.0"
        arch = ["x86_64"]
      }
    """)
    let m = loadManifest(path)
    check m.distro.name == "Zenit Linux"
    check m.distro.codename == "test"
    check m.distro.arches == @[archX86_64]

  test "brak pliku -> ZlbError z czytelną podpowiedzią":
    expect(ZlbError):
      discard loadManifest("/nieistniejaca/sciezka/distro.hcl")

  test "brak bloku distro { } -> ZlbError":
    let dir = createTempDir("zlbtest", "")
    defer: removeDir(dir)
    let path = dir / "distro.hcl"
    writeFile(path, "modules {\n  include = [\"base\"]\n}\n")
    expect(ZlbError):
      discard loadManifest(path)

  test "nieznana architektura -> ZlbError":
    let dir = createTempDir("zlbtest", "")
    defer: removeDir(dir)
    let path = dir / "distro.hcl"
    writeFile(path, """
      distro {
        name = "X"
        arch = ["nieznana-architektura-xyz"]
      }
    """)
    expect(ZlbError):
      discard loadManifest(path)

  test "tools { } usunięte z HCL -- stary blok jest cicho ignorowany, nie błędem":
    let dir = createTempDir("zlbtest", "")
    defer: removeDir(dir)
    let path = dir / "distro.hcl"
    writeFile(path, """
      distro {
        name = "X"
      }
      tools {
        auto_fetch = false
        allow_placeholder = true
      }
    """)
    # Stary blok tools {} z poprzedniej wersji manifestu nie powinien
    # wywalać parsowania -- po prostu nie ma już żadnego pola Manifest,
    # do którego by trafił.
    let m = loadManifest(path)
    check m.distro.name == "X"

  test "DefaultZpmReleaseUrl wskazuje na alias 'latest', nie przypięty tag":
    check "Zenit-Linux/zpm" in tools.DefaultZpmReleaseUrl
    check "/releases/latest/download/" in tools.DefaultZpmReleaseUrl

  test "pickLatestTagFromReleasesJson: bierze tag_name pierwszego wpisu (najnowszy, nawet pre-release)":
    # Kształt odpowiedzi GitHub REST API `GET /repos/{owner}/{repo}/releases`
    # -- lista posortowana od najnowszego, BEZ filtrowania prerelease/draft
    # (w przeciwieństwie do aliasu ".../releases/latest", który je pomija).
    let json = """
      [
        {"tag_name": "v0.1", "prerelease": true, "draft": false},
        {"tag_name": "v0.0.9", "prerelease": false, "draft": false}
      ]
    """
    check tools.pickLatestTagFromReleasesJson(json) == "v0.1"

  test "pickLatestTagFromReleasesJson: pusta lista releasów -> \"\"":
    check tools.pickLatestTagFromReleasesJson("[]") == ""

  test "pickLatestTagFromReleasesJson: błędny JSON -> \"\" (nie rzuca wyjątku)":
    check tools.pickLatestTagFromReleasesJson("nie jest jsonem {{{") == ""

  test "pickLatestTagFromReleasesJson: pusty string -> \"\"":
    check tools.pickLatestTagFromReleasesJson("") == ""

suite "modules (package.list w formacie HCL -- v0.3)":
  test "parsuje package.list z blokami HCL":
    let dir = createTempDir("zlbtest", "")
    defer: removeDir(dir)
    let modDir = dir / "core"
    createDir(modDir)
    writeFile(modDir / "package.list", """
      package "base" {}
      package "systemd" {
        backend = "apt"
      }
      package "kernel" {
        backend     = "own"
        variant     = "testing"
        description = "jądro testowe"
      }
    """)
    let mp = discoverModule(dir, "core")
    check mp.installList.len == 3
    check mp.installList[0].name == "base"
    check mp.installList[0].backend == ""
    check mp.installList[1].backend == "apt"
    check mp.installList[2].variant == "testing"
    check mp.installList[2].description == "jądro testowe"

  test "variant bez backend -> ZlbError":
    let dir = createTempDir("zlbtest", "")
    defer: removeDir(dir)
    let modDir = dir / "core"
    createDir(modDir)
    writeFile(modDir / "package.list", """
      package "zle" {
        variant = "testing"
      }
    """)
    expect(ZlbError):
      discard discoverModule(dir, "core")

  test "pusty package.list -> pusta lista, bez błędu":
    let dir = createTempDir("zlbtest", "")
    defer: removeDir(dir)
    let modDir = dir / "core"
    createDir(modDir)
    writeFile(modDir / "package.list", "# tylko komentarz\n")
    let mp = discoverModule(dir, "core")
    check mp.installList.len == 0

suite "toolset (GNU vs zenit -- distro.hcl toolset { })":
  test "domyślny profil to gnu, bez bloku toolset {}":
    let dir = createTempDir("zlbtest", "")
    defer: removeDir(dir)
    writeFile(dir / "distro.hcl", "distro { name = \"X\" codename = \"x\" version = \"1\" }")
    let m = loadManifest(dir / "distro.hcl")
    check m.toolset.profile == tpGnu
    check m.toolset.allowOverride == true
    check m.toolset.gnuModule == "toolset-gnu"
    check m.toolset.zenitModule == "toolset-zenit"

  test "toolset { profile = \"zenit\" } jest respektowane":
    let dir = createTempDir("zlbtest", "")
    defer: removeDir(dir)
    writeFile(dir / "distro.hcl", """
      distro { name = "X" codename = "x" version = "1" }
      toolset { profile = "zenit" }
    """)
    let m = loadManifest(dir / "distro.hcl")
    check m.toolset.profile == tpZenit

  test "nieznany profil -> ZlbError":
    let dir = createTempDir("zlbtest", "")
    defer: removeDir(dir)
    writeFile(dir / "distro.hcl", """
      distro { name = "X" codename = "x" version = "1" }
      toolset { profile = "busybox" }
    """)
    expect(ZlbError):
      discard loadManifest(dir / "distro.hcl")

  test "resolveToolsetProfile: brak override -> profil z manifestu":
    let cfg = ToolsetConfig(profile: tpZenit, allowOverride: true,
                             gnuModule: "toolset-gnu", zenitModule: "toolset-zenit")
    check resolveToolsetProfile(cfg, "") == tpZenit

  test "resolveToolsetProfile: --toolset nadpisuje, gdy allow_override":
    let cfg = ToolsetConfig(profile: tpGnu, allowOverride: true,
                             gnuModule: "toolset-gnu", zenitModule: "toolset-zenit")
    check resolveToolsetProfile(cfg, "zenit") == tpZenit

  test "resolveToolsetProfile: --toolset odrzucone, gdy allow_override=false":
    let cfg = ToolsetConfig(profile: tpGnu, allowOverride: false,
                             gnuModule: "toolset-gnu", zenitModule: "toolset-zenit")
    expect(ZlbError):
      discard resolveToolsetProfile(cfg, "zenit")

  test "withToolset: dopisuje moduł, gdy include niepuste i brak duplikatu":
    check withToolset(@["core"], "toolset-gnu") == @["core", "toolset-gnu"]

  test "withToolset: nie duplikuje, gdy moduł już wymieniony":
    check withToolset(@["core", "toolset-zenit"], "toolset-zenit") == @["core", "toolset-zenit"]

  test "withToolset: pusty include (skanowanie katalogowe) -> bez zmian":
    let empty: seq[string] = @[]
    check withToolset(empty, "toolset-gnu") == empty

suite "installerconfig (installer/config.hcl)":
  test "brak installer/config.hcl -> present=false, sensowne domyślne":
    let dir = createTempDir("zlbtest", "")
    defer: removeDir(dir)
    let cfg = loadInstallerConfig(dir)
    check cfg.present == false
    check cfg.locales == @["en_US.UTF-8"]

  test "parsuje installer/config.hcl i branding {}":
    let dir = createTempDir("zlbtest", "")
    defer: removeDir(dir)
    createDir(dir / "installer")
    writeFile(dir / "installer" / "config.hcl", """
      installer {
        desktop_selector = true
        desktops = ["gnome", "plasma", "none"]
        default_desktop = "gnome"
        locales = ["pl_PL.UTF-8", "en_US.UTF-8"]
        default_locale = "pl_PL.UTF-8"
        title = "Zenit Linux Installer"
      }
      branding {
        icon = "icon.png"
        banner = "banner.png"
      }
    """)
    let cfg = loadInstallerConfig(dir)
    check cfg.present == true
    check cfg.desktops == @["gnome", "plasma", "none"]
    check cfg.defaultDesktop == "gnome"
    check cfg.locales == @["pl_PL.UTF-8", "en_US.UTF-8"]
    check cfg.title == "Zenit Linux Installer"
    check cfg.brandingIcon == "icon.png"

  test "default_desktop spoza desktops -> ZlbError":
    let dir = createTempDir("zlbtest", "")
    defer: removeDir(dir)
    createDir(dir / "installer")
    writeFile(dir / "installer" / "config.hcl", """
      installer {
        desktops = ["gnome"]
        default_desktop = "plasma"
      }
    """)
    expect(ZlbError):
      discard loadInstallerConfig(dir)

  test "validateDesktops: brakujący modules/desktop-<id>/ -> błąd":
    let dir = createTempDir("zlbtest", "")
    defer: removeDir(dir)
    let cfg = InstallerConfig(present: true, desktops: @["gnome", "none"])
    let errs = validateDesktops(dir, cfg)
    check errs.len == 1
    check "desktop-gnome" in errs[0]

  test "validateDesktops: 'none' nigdy nie wymaga katalogu":
    let dir = createTempDir("zlbtest", "")
    defer: removeDir(dir)
    let cfg = InstallerConfig(present: true, desktops: @["none"])
    check validateDesktops(dir, cfg).len == 0

  test "validateDesktops: katalog obecny -> brak błędów":
    let dir = createTempDir("zlbtest", "")
    defer: removeDir(dir)
    createDir(dir / "modules" / "desktop-gnome")
    let cfg = InstallerConfig(present: true, desktops: @["gnome"])
    check validateDesktops(dir, cfg).len == 0

  test "validateInstallerBranding: brakujące pliki -> ostrzeżenia, nie błędy":
    let dir = createTempDir("zlbtest", "")
    defer: removeDir(dir)
    let cfg = InstallerConfig(present: true, brandingIcon: "missing.png", brandingBanner: "")
    let warns = validateInstallerBranding(dir, cfg)
    check warns.len == 1
    check "missing.png" in warns[0]

  test "validateDesktops: 'all' nigdy nie wymaga katalogu modules/desktop-all/":
    let dir = createTempDir("zlbtest", "")
    defer: removeDir(dir)
    let cfg = InstallerConfig(present: true, desktops: @["all", "none"])
    check validateDesktops(dir, cfg).len == 0

  test "default_desktop dowolne, gdy desktops zawiera 'all' -- brak ZlbError":
    let dir = createTempDir("zlbtest", "")
    defer: removeDir(dir)
    createDir(dir / "installer")
    writeFile(dir / "installer" / "config.hcl", """
      installer {
        desktops = ["all"]
        default_desktop = "cosmic"
      }
    """)
    let cfg = loadInstallerConfig(dir)
    check cfg.defaultDesktop == "cosmic"
