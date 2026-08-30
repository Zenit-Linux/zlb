import std/[os, strformat]
import ./paths
import ./zpm as zpmwrap

## v0.4 -- usunięty blok `tools { }` z distro.hcl (patrz też manifest.nim,
## types.nim, zenit/distro.hcl). Powód: `zpm` to jedyne narzędzie, którego
## zlb NAPRAWDĘ musi umieć skądś zdobyć samo (problem "jajko i kura" --
## bez zpm nie da się jeszcze niczego zainstalować W ROOTFS, więc "zainstaluj
## zpm przez zpm" nie ma sensu na starcie). Adres, skąd je pobrać, nie jest
## czymś, co ma sens jako opcja per-dystrybucja w distro.hcl -- to zawsze
## powinna być NAJNOWSZA wersja zpm z oficjalnego repo, więc zlb wie to
## SAM, na stałe (`DefaultZpmReleaseUrl` niżej, alias GitHuba "/latest/",
## nie przypięty numer wydania).
##
## `installer` NIE jest już pobierany bezpośrednio przez zlb w ogóle --
## to zwykły pakiet w ekosystemie `own` (patrz `modules/core/package.list`
## w repo zenit: `package "installer" { backend = "own" }`), instalowany
## przez `zpm install installer` w ramach normalnej instalacji pakietów
## modułu "core", DOKŁADNIE tak samo jak `zpm` sam siebie tam wymienia.
## Nie ma już żadnego osobnego mechanizmu "ściągnij binarkę installer z
## GitHuba" w tym pliku -- to była zbędna duplikacja tej samej ścieżki
## dostawy, którą i tak zapewnia zpm.

const DefaultZpmReleaseUrl* =
  "https://github.com/Zenit-Linux/zpm/releases/latest/download/zpm"
  ## `/releases/latest/download/<nazwa>` to stały alias GitHuba, który
  ## ZAWSZE wskazuje na najnowsze wydanie -- w przeciwieństwie do URL-a
  ## przypiętego do konkretnego tagu (np. `/v0.1/`), nie wymaga ręcznej
  ## aktualizacji w kodzie zlb przy każdym nowym wydaniu zpm.

proc downloadBinary(url, dest: string): bool =
  ## Pobiera przez `curl`/`wget` jako podproces (NIE `std/httpclient`).
  ##
  ## `std/httpclient` w Nim potrafi obsłużyć HTTPS TYLKO, gdy binarka zlb
  ## zostanie skompilowana z `-d:ssl` (i będzie miała dostępny/zalinkowany
  ## OpenSSL w czasie działania) -- inaczej `newHttpClient` rzuca w
  ## runtime "SSL support is not available. Cannot connect over SSL.
  ## Compile with -d:ssl to enable.", nawet gdy sam kod się skompilował
  ## bez błędu. Zamiast wymagać `-d:ssl` (obecności nagłówków OpenSSL na
  ## KAŻDEJ maszynie budującej zlb), wołamy `curl`/`wget` jako zwykły
  ## podproces -- dokładnie tak, jak już robi to oficjalne CI tego
  ## ekosystemu do pobierania samego zlb.
  if url.len == 0: return false
  createDir(parentDir(dest))
  echo &"==> [tools] pobieram {dest.extractFilename} z {url}"
  let tmp = dest & ".part"
  removeFile(tmp)
  var cmd = ""
  if findExe("curl").len > 0:
    cmd = &"curl -fsSL --retry 2 -o \"{tmp}\" \"{url}\""
  elif findExe("wget").len > 0:
    cmd = &"wget -q -O \"{tmp}\" \"{url}\""
  else:
    stderr.writeLine("==> [tools] ✘ pobieranie nie powiodło się: brak 'curl' i 'wget' w PATH -- " &
      "zainstaluj jedno z nich (np. `apt install curl`), zlb celowo nie linkuje własnego klienta TLS.")
    return false
  let exitCode = execShellCmd(cmd)
  if exitCode != 0 or not fileExists(tmp):
    removeFile(tmp)
    stderr.writeLine(&"==> [tools] ✘ pobieranie nie powiodło się (kod wyjścia {exitCode}) -- sprawdź URL i połączenie sieciowe")
    return false
  moveFile(tmp, dest)
  when defined(posix):
    discard execShellCmd(&"chmod +x \"{dest}\"")
  echo &"==> [tools] ✔ {dest}"
  true

proc ensureZpm(cacheDir: string): bool =
  let dest = cacheDir / "zpm"
  if fileExists(dest): return true
  if findExe("zpm").len > 0: return true  # już dostępne systemowo
  downloadBinary(DefaultZpmReleaseUrl, dest)

proc ensureBuildTools*(p: ProjectPaths, allowPlaceholder: bool) =
  ## Wywoływane na samym początku każdej komendy `zlb build ...`.
  ## `allowPlaceholder` pochodzi z flagi CLI `--allow-placeholder` (patrz
  ## zlb.nim), NIE z distro.hcl -- to świadoma decyzja per-uruchomienie
  ## ("dziś robię tylko inspekcję drzewa modułów"), nie własność
  ## dystrybucji, więc nie ma czego trzymać w manifeście.
  zpmwrap.allowPlaceholder = allowPlaceholder
  if allowPlaceholder:
    echo "==> [tools] UWAGA: --allow-placeholder -- brak realnego 'zpm' NIE przerwie builda " &
      "(instalacje pakietów zostaną tylko zasymulowane, głośno ostrzegane przy każdym użyciu)"

  let cacheDir = p.cacheDir / "tools"
  createDir(cacheDir)

  echo "==> [tools] sprawdzam zpm..."
  if not ensureZpm(cacheDir):
    echo "==> [tools] ! nie udało się zapewnić 'zpm' -- zlbpkg/zpm.nim przejdzie w tryb placeholder " &
      "(albo przerwie build, jeśli --allow-placeholder nie zostało podane)"

  # Spraw, żeby świeżo pobrany zpm był widoczny dla reszty ZLB w tym
  # samym uruchomieniu, bez wymagania restartu procesu. `installer` NIE
  # trafia tutaj -- instaluje go sam zpm jako zwykły pakiet, patrz
  # komentarz na górze pliku.
  zpmwrap.extraSearchDirs.add cacheDir
  putEnv("PATH", cacheDir & PathSep & getEnv("PATH"))
