import std/[os, osproc, strutils, strformat, httpclient]
import ./types
import ./paths
import ./zpm as zpmwrap

proc toolsCacheDir(p: ProjectPaths, m: Manifest): string =
  if m.tools.cacheDir.len > 0: m.tools.cacheDir
  else: p.cacheDir / "tools"

proc downloadBinary(url, dest: string): bool =
  if url.len == 0: return false
  createDir(parentDir(dest))
  echo &"==> [tools] pobieram {dest.extractFilename} z {url}"
  try:
    var client = newHttpClient(timeout = 60_000)
    defer: client.close()
    client.downloadFile(url, dest)
  except CatchableError as e:
    stderr.writeLine(&"==> [tools] ✘ pobieranie nie powiodło się: {e.msg}")
    return false
  when defined(posix):
    discard execShellCmd(&"chmod +x \"{dest}\"")
  echo &"==> [tools] ✔ {dest}"
  true

proc ensureTool(cacheDir, name, url: string): bool =
  let dest = cacheDir / name
  if fileExists(dest):
    return true
  if findExe(name).len > 0:
    # już dostępne systemowo -- nic do roboty, ale skopiuj do cache dla
    # spójności ze ścieżkami, które reszta ZLB sprawdza w pierwszej
    # kolejności (extraSearchDirs).
    return true
  downloadBinary(url, dest)

proc ensureBuildTools*(p: ProjectPaths, m: Manifest) =
  ## Wywoływane na samym początku każdej komendy `zlb build ...`.
  if not m.tools.autoFetch:
    echo "==> [tools] auto_fetch = false w distro.hcl -- pomijam bootstrap narzędzi"
    return

  let cacheDir = toolsCacheDir(p, m)
  createDir(cacheDir)

  echo "==> [tools] sprawdzam narzędzia budowania (zpm, installer)..."

  let haveZpm = ensureTool(cacheDir, "zpm", m.tools.zpmUrl)
  if not haveZpm:
    echo "==> [tools] ! nie udało się zapewnić 'zpm' -- zlbpkg/zpm.nim przejdzie w tryb placeholder"

  let haveInstaller = ensureTool(cacheDir, "installer", m.tools.installerUrl)
  if not haveInstaller:
    echo "==> [tools] ! nie udało się zapewnić 'installer' -- ISO zostanie zbudowane bez wbudowanego instalatora"

  # Spraw, żeby świeżo pobrane binarki były widoczne dla reszty ZLB w tym
  # samym uruchomieniu, bez wymagania restartu procesu:
  zpmwrap.extraSearchDirs.add cacheDir
  putEnv("PATH", cacheDir & PathSep & getEnv("PATH"))
