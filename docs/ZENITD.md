# zenitd zamiast systemd

Etap `init` (dla `init.system = "zenitd"`):

1. **systemd:** z zpm — atrapa `Provides` + blokady już w etapie `packages` (zob. docs/INIT.md); bez zpm — `rpm -e --nodeps` pakietów z `init.systemd_packages` po instalacji + blokada.
2. Pobranie zenitd: `git clone --depth 1 --branch <ref> <repo>` do `<cache_dir>/zenitd-src` (lub `init.source = "path"`).
3. Zbudowanie na hoście: `init.build_cmd` (domyślnie `z# build --release`). Przy `init.build = false` kopiowana jest gotowa `init.binary`.
4. `DESTDIR=<rootfs> PREFIX=/usr bash scripts/install.sh --no-build --zenit` — oficjalny instalator zenitd. Flaga **`--zenit`** (dodana w tej wersji install.sh)
   włącza układ usr-merge i `SystemdUnitCompat=yes` w nowo tworzonym `zenit.conf`, żeby zenitd czytał jednostki z pakietów RPM.
5. **Dowiązania `/sbin/init` i `/sbin/zenitd`.** Oryginalny `install.sh` robił `ln -sf ../usr/lib/zenit/zenitd $DESTDIR/sbin/init`; na openSUSE `/sbin` to
   dowiązanie do `usr/sbin`, link lądował w `/usr/sbin` i `../usr/lib/…` wskazywało `/usr/usr/lib/…` — `exec /sbin/init` kończył się ENOENT (odtworzone testem).
   Poprawiony `install.sh` tworzy linki bezwzględne. zlb dodatkowo naprawia je po instalacji (dla starszych wersji skryptu) i weryfikuje w chroot
   zarówno `readlink -f`, jak i realnym `test -x /sbin/init` (busybox `readlink -f` rozwiązuje względem tekstu ścieżki, nie jak jądro).
6. Cel domyślny (`init.default_target`) i `zenitctl enable <jednostka>` offline w chroot dla każdej pozycji `init.enable`.
7. Autologin live: drop-in `/etc/zenit/system/getty@tty1.service.d/autologin.conf` (`ExecStart=` reset + `agetty --autologin`).
8. Kernel: `init=/sbin/init`; initramfs: dracut bez modułów systemd (`omit`), moduł `dmsquash-live`.
