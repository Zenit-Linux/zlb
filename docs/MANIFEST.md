# zlb.toml — manifest

Wszystkie sekcje są opcjonalne (wartości domyślne w `src/config.zsharp`, `defaults()`). Każdy klucz można nadpisać z CLI:
`--set sekcja.klucz=wartość` (bool/liczba rozpoznawane; dla kluczy-list wartości po przecinku).

## [distro]
| klucz | domyślnie | opis |
|---|---|---|
| name, id, version, codename | Zenit Linux / zenit / rolling | `id`: `[a-z0-9._-]`; `version` wymagane |
| arch | x86_64 | `x86_64` albo `aarch64` (aarch64: tylko UEFI → `boot.bios = false`) |
| base | opensuse-tumbleweed | jedyna obsługiwana baza |
| hostname, locale, keymap, timezone | zenit, en_US.UTF-8, us, UTC | zapisywane do `/etc/hostname`, `locale.conf`, `vconsole.conf`, `localtime` |
| iso_label | z `id`+`version` | etykieta woluminu (≤ 32 znaki); używana w `root=live:CDLABEL=` |
| publisher, url | | metadane ISO |

## [build]
`work_dir` (build), `output_dir` (out), `cache_dir` (.zlb-cache), `iso_name` (`{id}-{version}-{arch}.iso`),
`formats` (`iso`, `squashfs`, `tar`, `rootfs`), `compression` (zstd/xz/gzip/lz4), `compression_level` (zstd), `block_size` (1M),
`profile` (live; widoczny w warunkach `[profile=…]` listy pakietów), `tags` (warunki `[tag=…]`),
`source_date_epoch` (puste = brak; ustawione → znaczniki czasu squashfs/ISO deterministyczne).

## [repos]
`defaults` (true: Tumbleweed OSS + non-OSS), `mirror` (https://download.opensuse.org), `gpg_auto_import`, `gpgcheck`.
Własne repozytoria:
```toml
[repos.repo.packman]
name = "Packman"
url = "https://ftp.gwdg.de/pub/linux/misc/packman/suse/openSUSE_Tumbleweed/"
priority = 90
gpgcheck = true
```
Pakiet z konkretnego repo: `ffmpeg@packman` w `zlb.list`. Klucze GPG: pliki w `keys/`.

## [packages]
`manager` (`auto` | `zypper` | `zpm`; auto = zpm dla obrazów bez systemd, gdy zpm jest dostępny — zob. docs/INIT.md),
`list` (packages/zlb.list), `recommends` (false), `vendor_change` (true), `download_in_advance` (true), `exclude_docs` (true),
`lock` (wzorce do `zypper addlock` przed instalacją), `remove_nodeps` (po instalacji `rpm -e --nodeps`, dodatkowo do `!pkg` z listy).

## [init], [init.custom], [zpm]
`init.system` = `zenitd` | `systemd` | `custom` | `none` — wybór init obrazu (docs/INIT.md). Wspólne: `name` (nazwa init widoczna w warunkach `[init=…]`
listy pakietów; domyślnie = `system`), `profile` (profil zpm; domyślnie wg `system`).
Dla `zenitd`: `source` (git|path), `repo`, `ref`, `path`, `build` (true: `build_cmd` na hoście), `binary` (gotowa binarka, gdy `build = false`),
`installer` (scripts/install.sh), `prefix` (/usr), `compat` (aplety systemctl/journalctl/…), `default_target`, `enable` (jednostki włączane offline
przez `zenitctl enable`), `remove_systemd`, `systemd_packages` (używane tylko bez zpm).
Dla `custom` (dowolny init, np. OpenRC/runit/s6):
```toml
[init]
system = "custom"
name = "openrc"                 # opcjonalnie, do warunków [init=openrc] w zlb.list
profile = "nosystemd"           # profil zpm
[init.custom]
init_path = "/sbin/openrc-init" # parametr jądra init= (wymagane, ścieżka bezwzględna)
packages = ["openrc"]           # dodawane do listy pakietów
block_systemd = true            # obraz bez systemd (zpm: atrapa + blokady)
post = ["rc-update add devfs sysinit"]   # polecenia w chroot po instalacji
```
`[zpm]`: `binary` (ścieżka do zpm; domyślnie z PATH), `install_in_image` (true: zpm + `/etc/zpm/zpm.conf` trafiają do obrazu).

## [users], [live]
`users.root_password_hash` (hash crypt, np. `openssl passwd -6`), `users.lock_root`, `[[users.account]]` (`name`, `uid`, `shell`, `groups`, `sudo`, `password_hash`, `ssh_keys`).
`live`: `enabled`, `user`, `password_hash` (puste = bez hasła), `groups`, `autologin` (drop-in getty zenitd), `overlay` (`tmpfs` → overlayfs w RAM; inna wartość → surowe `rd.live.overlay=`), `kernel_params`.

## [initrd], [boot]
`initrd`: `add` (dmsquash-live), `omit` (systemd, systemd-initrd, systemd-networkd, plymouth), `drivers`, `extra_args` (do dracuta).
`boot`: `bios`, `uefi`, `secure_boot` (eksperymentalne: shim + podpisany grub z rootfs), `timeout`, `menu_title`, `kernel_params`.
Parametry jądra budowane są z: `root=live:CDLABEL=…`, `live.kernel_params`, `init=/sbin/init` (dla zenitd), `boot.kernel_params`.

## [cleanup], [checksums], [dirs]
`cleanup`: `paths`, `truncate_logs`, `reset_machine_id`, `remove_ssh_host_keys`. `checksums`: `sha256`, `sign_key` (GPG, podpis `.asc`).
`dirs`: nazwy katalogów projektu (domyślne jak w README).
