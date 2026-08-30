import std/[os, strutils, strformat]
import ./types
import ./hcl

const AllDesktopsSentinel* = "all"
  ## Wartość specjalna w `installer.desktops` -- oznacza "użytkownik może
  ## wybrać DOWOLNE środowisko graficzne z pełnego katalogu znanych przez
  ## instalator" (patrz `installerpkg/desktops.nim::KnownDesktops` w repo
  ## `installer` -- ta lista musi być tam, nie tutaj, bo to instalator w
  ## runtime rozwija "all" do pełnej listy, zlb tylko przepuszcza sentinel
  ## przez walidację bez wymagania dla NIEGO SAMEGO katalogu modułu).
  ## Nie ma sensu jako `defaultDesktop` (nie jest realnym środowiskiem).

## v0.4 -- NIE jest już placeholderem: zlb zna teraz źródło Zenit
## Installer (repo `installer`) i faktycznie:
##   1. waliduje, że każde zadeklarowane `installer.desktops` (poza
##      "none") ma odpowiadający katalog `modules/desktop-<id>/` (patrz
##      `validateDesktops`) -- inaczej instalator mógłby zaoferować
##      środowisko, które nigdy nie trafiło do żadnego package.list,
##      i budowa dokumentowałaby coś, co w praktyce się nie zainstaluje;
##   2. embeduje `installer/config.hcl` verbatim + pliki brandingu do
##      rootfs (patrz `rootfs.nim::embedInstallerConfig`), skąd Zenit
##      Installer czyta je w trakcie działania (ten sam parser hcl-nim,
##      patrz `installerpkg/config.nim` w repo `installer`).
##
## Konwencja `modules/desktop-<id>/`: każdy wpis w `installer.desktops`
## (poza specjalnym `"none"`, oznaczającym instalację bez GUI) odpowiada
## katalogowi modułu `modules/desktop-<id>/package.list`, zawierającemu
## metapakiet (typowo `zenit-desktop-<id>`, backend `own`) który zpm
## rozwija na pełny zestaw pakietów danego środowiska. Sam ten moduł NIE
## jest automatycznie dołączany do `modules.include` w distro.hcl (użytkownik
## wybiera desktop PODCZAS instalacji, nie podczas budowania obrazu) --
## `installer` instaluje go POST-instalacyjnie przez `zpm --root=<target>
## install zenit-desktop-<id>` (patrz installerpkg/executor.nim w repo
## `installer`). Ta funkcja tylko sprawdza, że katalog (i więc metapakiet)
## w ogóle istnieje w projekcie, zanim ISO w ogóle powstanie.

proc defaultInstallerConfig(): InstallerConfig =
  InstallerConfig(
    present: false,
    desktopSelector: false,
    desktops: @[],
    defaultDesktop: "",
    defaultLocale: "en_US.UTF-8",
    locales: @["en_US.UTF-8"],
    allowManualPartitioning: true,
    title: "",
    brandingIcon: "icon-no-bg.png",
    brandingBanner: "banner.png"
  )

proc loadInstallerConfig*(projectDir: string): InstallerConfig =
  let path = projectDir / "installer" / "config.hcl"
  result = defaultInstallerConfig()
  if not fileExists(path):
    return  # present=false -- brak instalatora w tym projekcie, to nie błąd

  let root = parseHcl(readFile(path))  # rzuca ZlbError samo z siebie, patrz hcl.nim
  result.present = true

  let installerBlk = root.getBlock("installer")
  if installerBlk != nil:
    result.desktopSelector = installerBlk.getBool("desktop_selector", result.desktopSelector)
    let desktops = installerBlk.getStrList("desktops")
    if desktops.len > 0: result.desktops = desktops
    result.defaultDesktop = installerBlk.getStr("default_desktop", result.defaultDesktop)
    result.defaultLocale = installerBlk.getStr("default_locale", result.defaultLocale)
    let locales = installerBlk.getStrList("locales")
    if locales.len > 0: result.locales = locales
    result.allowManualPartitioning = installerBlk.getBool(
      "allow_manual_partitioning", result.allowManualPartitioning)
    result.title = installerBlk.getStr("title", result.title)

  let brandingBlk = root.getBlock("branding")
  if brandingBlk != nil:
    result.brandingIcon = brandingBlk.getStr("icon", result.brandingIcon)
    result.brandingBanner = brandingBlk.getStr("banner", result.brandingBanner)

  # "all" w desktops otwiera pełny katalog instalatora (patrz
  # AllDesktopsSentinel) -- default_desktop wtedy może być DOWOLNYM
  # znanym instalatorowi środowiskiem, nie tylko jednym z jawnie
  # wymienionych w tym pliku, więc pomijamy tę kontrolę zamiast fałszywie
  # odrzucać poprawny config.
  if result.defaultDesktop.len > 0 and result.desktops.len > 0 and
      AllDesktopsSentinel notin result.desktops and
      result.defaultDesktop notin result.desktops:
    raise newException(ZlbError,
      &"{path}: installer.default_desktop '{result.defaultDesktop}' nie występuje w installer.desktops " &
      &"({result.desktops.join(\", \")})")

  if result.defaultLocale.len > 0 and result.locales.len > 0 and
      result.defaultLocale notin result.locales:
    raise newException(ZlbError,
      &"{path}: installer.default_locale '{result.defaultLocale}' nie występuje w installer.locales " &
      &"({result.locales.join(\", \")})")

proc validateInstallerBranding*(projectDir: string, cfg: InstallerConfig): seq[string] =
  ## Zwraca listę OSTRZEŻEŃ (nie błędów -- brakujący plik brandingu nie
  ## blokuje builda, może być dodany później) o plikach branding
  ## wskazanych w installer/config.hcl, których nie ma w overlays/branding/.
  result = @[]
  if not cfg.present: return
  let brandingDir = projectDir / "overlays" / "branding"
  if cfg.brandingIcon.len > 0 and not fileExists(brandingDir / cfg.brandingIcon):
    result.add &"installer/config.hcl wskazuje branding.icon='{cfg.brandingIcon}', ale " &
      &"{brandingDir / cfg.brandingIcon} nie istnieje"
  if cfg.brandingBanner.len > 0 and not fileExists(brandingDir / cfg.brandingBanner):
    result.add &"installer/config.hcl wskazuje branding.banner='{cfg.brandingBanner}', ale " &
      &"{brandingDir / cfg.brandingBanner} nie istnieje"

proc validateDesktops*(projectDir: string, cfg: InstallerConfig): seq[string] =
  ## Zwraca listę BŁĘDÓW (w przeciwieństwie do brandingu, brakujący
  ## katalog modułu środowiska graficznego to prawdziwy błąd konfiguracji
  ## -- instalator zaoferowałby coś, co nigdy się nie zainstaluje).
  ## Wołający (zlb.nim::cmdManifestValidate / cmdBuildIso) decyduje, czy
  ## te błędy są fatalne (validate: tak, build: też -- patrz wywołania).
  ##
  ## `"all"` (patrz `AllDesktopsSentinel`) jest CELOWO pomijane -- to nie
  ## jest nazwa realnego środowiska/modułu, tylko instrukcja dla
  ## instalatora "pokaż pełny katalog". Nie wymaga (i nie może wymagać)
  ## `modules/desktop-all/`.
  result = @[]
  if not cfg.present: return
  for id in cfg.desktops:
    if id == "none" or id == AllDesktopsSentinel: continue
    let modDir = projectDir / "modules" / ("desktop-" & id)
    if not dirExists(modDir):
      result.add &"installer/config.hcl wymienia desktop '{id}', ale {modDir} nie istnieje " &
        &"(oczekiwano modules/desktop-{id}/package.list z metapakietem tego środowiska)"
