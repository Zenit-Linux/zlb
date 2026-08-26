import std/[os, strutils, strformat]
import ./types
import ./hcl

## v0.3 -- PLACEHOLDER (świadomie oznaczony jako taki): "installer/
## config.hcl <- konfiguracja instalatora czy ma byc w instalatorze kilka
## srodowisk graficznych do wyboru itd. (to narazie placeholder bo nie
## znasz kodu zrodlowego instalatora ale jak poznasz to rozbudujesz dwa
## naraz instalator i zlb)" -- cytat z wymagań.
##
## Ten moduł parsuje `installer/config.hcl`, JEŚLI istnieje w projekcie
## (katalog `installer/` jest OPCJONALNY -- projekty budujące obrazy bez
## instalatora, np. kontenery serwerowe, nie muszą go mieć). Brak pliku
## to NIE błąd builda.
##
## KIEDY POJAWI SIĘ prawdziwy kod źródłowy Zenit Installer, ten plik
## (i `InstallerConfig` w types.nim) wymaga przeglądu i prawdopodobnie
## rozszerzenia o realne opcje instalatora, których teraz nie znamy
## (np. schemat partycjonowania, sieć w trakcie instalacji, konta
## użytkowników tworzone podczas instalacji) -- pola poniżej to
## najbardziej prawdopodobny, ale NIE ostateczny kontrakt.

proc defaultInstallerConfig(): InstallerConfig =
  InstallerConfig(
    present: false,
    desktopSelector: false,
    desktops: @[],
    defaultDesktop: "",
    defaultLocale: "en_US.UTF-8",
    locales: @["en_US.UTF-8"],
    allowManualPartitioning: true,
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

  let brandingBlk = root.getBlock("branding")
  if brandingBlk != nil:
    result.brandingIcon = brandingBlk.getStr("icon", result.brandingIcon)
    result.brandingBanner = brandingBlk.getStr("banner", result.brandingBanner)

  if result.defaultDesktop.len > 0 and result.desktops.len > 0 and
      result.defaultDesktop notin result.desktops:
    raise newException(ZlbError,
      &"{path}: installer.default_desktop '{result.defaultDesktop}' nie występuje w installer.desktops " &
      &"({result.desktops.join(\", \")})")

proc validateInstallerBranding*(projectDir: string, cfg: InstallerConfig): seq[string] =
  ## Zwraca listę OSTRZEŻEŃ (nie błędów -- brakujący branding nie blokuje
  ## builda, bo to placeholder) o plikach branding wskazanych w
  ## installer/config.hcl, których nie ma w overlays/branding/.
  result = @[]
  if not cfg.present: return
  let brandingDir = projectDir / "overlays" / "branding"
  if cfg.brandingIcon.len > 0 and not fileExists(brandingDir / cfg.brandingIcon):
    result.add &"installer/config.hcl wskazuje branding.icon='{cfg.brandingIcon}', ale " &
      &"{brandingDir / cfg.brandingIcon} nie istnieje"
  if cfg.brandingBanner.len > 0 and not fileExists(brandingDir / cfg.brandingBanner):
    result.add &"installer/config.hcl wskazuje branding.banner='{cfg.brandingBanner}', ale " &
      &"{brandingDir / cfg.brandingBanner} nie istnieje"
