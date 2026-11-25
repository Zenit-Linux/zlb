# zlb
Source code of Zenit Linux Builder.

**zlb** buduje produkcyjne obrazy ISO (live, hybrydowe BIOS + UEFI) z **openSUSE Tumbleweed** — przede wszystkim dla
**Zenit Linux**, ale nadaje się do dowolnej dystrybucji opartej na Tumbleweed. Napisany w całości w [Z#](https://github.com/Zenit-Linux/Z-Sharp).
Zamiast KIWI NG: prosty, deterministyczny potok etapów, jeden manifest, zwykłe skrypty powłoki jako hooki.

Wybierasz init obrazu: **systemd**, **zenitd**, **własny** (`custom`: OpenRC, runit, s6…) albo **none** — [docs/INIT.md](docs/INIT.md).
Obrazy bez systemd budują się z **zpm** (osobny projekt, nakładka na zypper; sposób dystrybucji do ustalenia: pakiet-atrapa `Provides: systemd` + blokady, więc systemd nie wraca jako zależność). zlb szuka `zpm` w PATH albo pod `zpm.binary`.
zenitd instalowany jest skryptem [`scripts/install.sh --zenit`](https://github.com/Zenit-Linux/zenitd/blob/main/scripts/install.sh) ([docs/ZENITD.md](docs/ZENITD.md)).

## Struktura projektu dystrybucji

```
zlb.toml               główny manifest (docs/MANIFEST.md)
packages/zlb.list      lista pakietów (docs/PACKAGES.md); %include innych list
after.packages/        skrypty w chroot zaraz po instalacji pakietów
hooks/                 skrypty: NN-x.sh (chroot) oraz hooks/<etap>/ (pre-bootstrap, post-bootstrap, chroot, pre-image, post-image)
includes.chroot/       nakładka plików na rootfs (*.zlbtpl = szablony {{distro.name}})
includes.iso/          nakładka plików na korzeń ISO
keys/                  klucze GPG repozytoriów (*.asc|*.gpg|*.key)
repos.d/               dodatkowe pliki *.repo
boot/                  zarezerwowane (motyw GRUB)
```

Gotowe przykłady (utworzone przez `zlb new`): [`examples/zenit`](examples/zenit), [`examples/minimal`](examples/minimal) (systemd), [`examples/custom`](examples/custom) (własny init).

## Szybki start

```
zlb new mojadystrybucja --template zenit
cd mojadystrybucja
zlb check                  # walidacja manifestu, listy pakietów i hooków
zlb build --dry-run        # pokaż wszystkie polecenia, nic nie wykonuj
sudo zlb build             # zbuduj  →  out/zenit-2026.11-x86_64.iso (+ .sha256, .packages)
```

Budowa wymaga roota (chroot, mount, `zypper --root`) i hosta z narzędziami z `zlb doctor`. Najprościej w kontenerze Tumbleweed:
[`Containerfile`](Containerfile), `podman run --privileged -v "$PWD":/work zlb-builder zlb build`.

## Polecenia

| Polecenie | Opis |
|---|---|
| `zlb new KATALOG [--template zenit\|minimal\|custom]` | szkielet projektu |
| `zlb build` | potok: prepare → pre-bootstrap → repos → packages → post-bootstrap → after-packages → init → overlay → system → hooks → initrd → cleanup → pre-image → image → post-image → finalize |
| `zlb check` / `zlb list-packages` / `zlb stages` / `zlb doctor` | diagnostyka bez budowania |
| `zlb verify [ISO]` | kontrola ISO: suma, BIOS/UEFI, etykieta, jądro/initrd/squashfs, brak systemd w manifeście |
| `zlb run [ISO] [--uefi]` | start ISO w QEMU |
| `zlb diff STARY.packages NOWY.packages` | różnice pakietów między obrazami |
| `zlb chroot` | powłoka w rootfs (debug) |
| `zlb clean [--all]` | sprzątanie |

Przydatne opcje `build`: `--dry-run`, `--resume`, `--from E`, `--until E`, `--only E`, `--set klucz=wartość`, `--profile`, `--arch`, `--tag`, `-v`.

## Instalacja zlb

```
zsc build src/main.zsharp --emit zbc -o zlb.zbc && zsc0 bundle zlb.zbc -o zlb    # binarka standalone
sudo scripts/install.sh                                                            # /usr/local/bin/zlb
```
albo bez kompilacji: `zsc0 run src/main.zsharp build`.

## Testy

```
ZSC0=/ścieżka/do/zsc0 scripts/test.sh                                   # 127 asercji (bez roota)
sudo ZSC0=zsc0 ZENITD_SRC=/ścieżka/zenitd tests/e2e/run.sh              # pełna budowa bez --dry-run (atrapa zypper)
```
Szczegóły tego, co jest przetestowane na prawdziwych narzędziach, a co nie: [docs/STATUS.md](docs/STATUS.md).

Licencja: MPL-2.0.
