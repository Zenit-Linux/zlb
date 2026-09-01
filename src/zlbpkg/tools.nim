import std/[os, strformat, json, osproc]
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

const
  zpmOwner = "Zenit-Linux"
  zpmRepoName = "zpm"

const DefaultZpmReleaseUrl* =
  &"https://github.com/{zpmOwner}/{zpmRepoName}/releases/latest/download/zpm"
  ## `/releases/latest/download/<nazwa>` to stały alias GitHuba, który
  ## ZWYKLE wskazuje na najnowsze wydanie -- w przeciwieństwie do URL-a
  ## przypiętego do konkretnego tagu (np. `/v0.1/`), nie wymaga ręcznej
  ## aktualizacji w kodzie zlb przy każdym nowym wydaniu zpm.
  ##
  ## PUŁAPKA (NAPRAWIONE poniżej w `ensureZpm`): ten alias ZAWSZE pomija
  ## release'y oznaczone jako "pre-release" albo "draft" -- to zachowanie
  ## GitHuba, nie coś, co zlb kontroluje. Jeśli NAJNOWSZY (albo wręcz
  ## JEDYNY) release repo zpm jest oznaczony jako pre-release (częste przy
  ## wczesnych wydaniach 0.x), `/releases/latest/download/zpm` zwróci 404,
  ## MIMO że release i asset faktycznie istnieją i są pobieralne pod
  ## przypiętym URL-em `/releases/download/<tag>/zpm`. Same demaskowanie
  ## tego przez zwykłe "sprawdź URL i połączenie sieciowe" wprowadzało w
  ## błąd -- URL był poprawny, połączenie działało, po prostu GitHub
  ## celowo nie uznaje pre-release za "latest".

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

proc pickLatestTagFromReleasesJson*(jsonText: string): string =
  ## Czysta funkcja (BEZ sieci, więc łatwo testowalna) -- bierze treść
  ## zwróconą przez GitHub REST API `GET /repos/{owner}/{repo}/releases`
  ## (lista WSZYSTKICH release'ów danego repo, posortowana od
  ## najnowszego -- w PRZECIWIEŃSTWIE do endpointu/aliasu `.../latest`,
  ## który cicho POMIJA pre-release i draft) i zwraca `tag_name`
  ## PIERWSZEGO wpisu, czyli faktycznie najnowszy tag, niezależnie od
  ## flagi `prerelease`/`draft`. Pusty/błędny JSON, pusta lista albo brak
  ## klucza `tag_name` -> "".
  if jsonText.len == 0: return ""
  try:
    let parsed = parseJson(jsonText)
    if parsed.kind == JArray and parsed.len > 0 and parsed[0].kind == JObject:
      return parsed[0]{"tag_name"}.getStr("")
  except CatchableError:
    discard
  ""

proc fallbackPinnedZpmUrl(): string =
  ## Wywoływane TYLKO gdy pobranie spod `DefaultZpmReleaseUrl` (alias
  ## "latest") zawiedzie -- odpytuje REST API o pełną (nieprzefiltrowaną)
  ## listę release'ów repo zpm i buduje URL przypięty do faktycznie
  ## najnowszego taga (patrz `pickLatestTagFromReleasesJson`). Zwraca ""
  ## jeśli `curl` niedostępne albo zapytanie/parsowanie się nie powiedzie
  ## -- wołający wtedy po prostu zgłasza niepowodzenie tak jak dotychczas.
  if findExe("curl").len == 0: return ""
  let apiUrl = &"https://api.github.com/repos/{zpmOwner}/{zpmRepoName}/releases"
  let cmd = &"curl -fsSL --retry 2 -H \"Accept: application/vnd.github+json\" \"{apiUrl}\""
  let (output, exitCode) = execCmdEx(cmd)
  if exitCode != 0: return ""
  let tag = pickLatestTagFromReleasesJson(output)
  if tag.len == 0: return ""
  &"https://github.com/{zpmOwner}/{zpmRepoName}/releases/download/{tag}/zpm"

proc ensureZpm(cacheDir: string): bool =
  let dest = cacheDir / "zpm"
  if fileExists(dest): return true
  if findExe("zpm").len > 0: return true  # już dostępne systemowo
  if downloadBinary(DefaultZpmReleaseUrl, dest): return true
  # `latest` zawiodło -- prawdopodobnie najnowszy release jest oznaczony
  # jako pre-release/draft (patrz komentarz przy `DefaultZpmReleaseUrl`).
  # Zanim poddamy się na dobre, sprawdź przez REST API, czy istnieje
  # jakikolwiek faktyczny release, i spróbuj pobrać spod przypiętego URL-a.
  echo "==> [tools] alias 'latest' nie znalazł release'u (może być oznaczony jako pre-release) -- " &
    "sprawdzam REST API GitHuba o faktycznie najnowszy tag..."
  let fallbackUrl = fallbackPinnedZpmUrl()
  if fallbackUrl.len == 0:
    stderr.writeLine("==> [tools] ✘ nie udało się ustalić najnowszego taga przez REST API -- " &
      "sprawdź, czy repo zpm ma w ogóle jakikolwiek release, albo połączenie z api.github.com")
    return false
  downloadBinary(fallbackUrl, dest)

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
