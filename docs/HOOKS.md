# Hooki i after.packages

| Miejsce | Gdzie działa | Kiedy |
|---|---|---|
| `after.packages/NN-x.sh` | chroot | zaraz po instalacji pakietów, przed zenitd/overlayem |
| `hooks/NN-x.sh` | chroot | po init, overlayu, użytkownikach, przed initrd |
| `hooks/pre-bootstrap/` | host | przed repozytoriami i pakietami |
| `hooks/post-bootstrap/` | host | po instalacji pakietów (API jądra zamontowane w rootfs) |
| `hooks/chroot/` | chroot | jak `hooks/NN-x.sh` |
| `hooks/pre-image/` | host | po cleanup, przed squashfs/ISO |
| `hooks/post-image/` | host | po ISO, przed sumami kontrolnymi |

Zasady: kolejność = sortowanie po nazwie (`10-`, `20-`); plik musi mieć shebang (uruchamiany bezpośrednio, `zlb check` ostrzega);
przyrostek `.host` / `.chroot` wymusza miejsce wykonania; `*.disabled`, `*~`, `*.md`, `*.txt`, `.ukryte` są pomijane;
błąd (kod ≠ 0) przerywa budowę.

Środowisko: `ZLB_STAGE ZLB_ARCH ZLB_DISTRO_ID ZLB_DISTRO_NAME ZLB_VERSION ZLB_INIT ZLB_PROFILE ZLB_HOSTNAME ZLB_LIVE_USER`;
hooki host dodatkowo `ZLB_ROOTFS ZLB_ISOROOT ZLB_WORKDIR ZLB_OUTDIR ZLB_PROJECT`.

## Nakładki
`includes.chroot/` kopiowane `cp -a` na rootfs (po zenitd, przed hookami `chroot`); `includes.iso/` na korzeń ISO (po wygenerowaniu
`grub.cfg`, więc można go nadpisać). Pliki `*.zlbtpl` to szablony: `{{distro.name}}`, `{{distro.version}}`, `{{init.system}}`, dowolny klucz manifestu.
