# Status — co jest sprawdzone, a co nie

## Sprawdzone automatycznie
* `scripts/test.zsharp` — 127 asercji w interpreterze stage0: parser listy pakietów (warunki, include, błędy z linią), konfiguracja i walidacja (także pól
  trafiających do powłoki: hostname, strefa, nazwy użytkowników), `--set`, wybór init/menedżera (`zenitd`/`systemd`/`custom`, `auto`/`zpm`/`zypper`),
  szablony nakładek, grub.cfg, argumenty xorriso/QEMU, parsery `verify`, diff manifestów, wykrywanie wycieku systemd, runner (kod wyjścia, log, env),
  blokada budowy (żywy/martwy PID), prawdziwe kopiowanie nakładek, scaffold.
* Ręcznie/skryptowo na prawdziwych narzędziach: kill -9 w trakcie budowy → następny przebieg sprząta pozostałe mounty i martwą blokadę; dwie równoległe budowy
  są odrzucane; `zlb clean` odmontowuje pozostałości; ISO uruchomione w QEMU (BIOS i UEFI) dochodzi przez GRUB do ładowania jądra.
* zlb → zpm: build z prawdziwym zpm (binarka standalone), prawdziwym `rpm`/`rpmbuild` i atrapą zypper — atrapa `zpm-stub-zenitd` w bazie rpm obrazu,
  `zpm` i `/etc/zpm/zpm.conf` w obrazie.

## NIE sprawdzone (brak openSUSE z dostępem do repozytoriów)
realny `zypper --root` (w tym `addlock`, format `/etc/zypp/locks`, parser `--dry-run` oparty na przykładowym wyjściu), rpm scriptlets w chroot,
dracut z `dmsquash-live` bez systemd, uruchomienie zenitd jako PID 1 z tego obrazu, zachowanie `zypper dup` wobec pakietu-atrapy, Secure Boot (shim), aarch64.
Pierwsze prawdziwe zbudowanie na Tumbleweed może wymagać korekt (nazwy pakietów w przykładowej liście). Raportuj z `build/zlb.log`.

## Uwagi o Z# stage0
Brak `unset`, `array_merge`, `use` w domknięciach; `push()`/`sort()`/`filter()` nie modyfikują w miejscu; `match` to słowo kluczowe; `"\x1b"` nie jest escape'em
(użyj `chr(27)`). Dwa błędy budowy stage0 (`runtime`/`zs-runtime` w `stage0/Cargo.toml`, brak `ExprKind::Spread`) naprawiono w dołączonym `Z-Sharp-main.zip`.
