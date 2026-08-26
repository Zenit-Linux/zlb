import std/[unittest, os, tempfiles, strutils]
import ../src/zlbpkg/hcl
import ../src/zlbpkg/manifest
import ../src/zlbpkg/types
import ../src/zlbpkg/modules

## v0.2 -- zamyka lukę "Brak testów jednostkowych dla hcl.nim/manifest.nim
## w zlb (parser HCL w zlb i zpm to niezależne implementacje -- zpm ma
## teraz testy regresyjne, zlb nie)". Uruchamiane przez `nimble test`.

suite "hcl (zlb -- implementacja niezależna od zpm/hcl.nim)":
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

  test "tools { } domyślne wartości i allow_placeholder=false domyślnie":
    let dir = createTempDir("zlbtest", "")
    defer: removeDir(dir)
    let path = dir / "distro.hcl"
    writeFile(path, """
      distro {
        name = "X"
      }
    """)
    let m = loadManifest(path)
    check m.tools.autoFetch == true
    check m.tools.allowPlaceholder == false
    check "Zenit-Linux" in m.tools.zpmUrl

  test "tools { allow_placeholder = true } jest respektowane":
    let dir = createTempDir("zlbtest", "")
    defer: removeDir(dir)
    let path = dir / "distro.hcl"
    writeFile(path, """
      distro {
        name = "X"
      }
      tools {
        allow_placeholder = true
      }
    """)
    let m = loadManifest(path)
    check m.tools.allowPlaceholder == true

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
