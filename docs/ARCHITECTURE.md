# Architektura zlb

```
cli → build (Session: mounty, znaczniki .state) → etapy
        repos ─ packages ─ hooks ─ initsys ─ overlay ─ system ─ initrd ─ cleanup ─ image ─ outputs
runner (jedyne miejsce uruchamiające procesy: --dry-run, log do pliku, env)   ctx (konfiguracja + ścieżki)
config (zlb.toml + domyślne + walidacja)   pkglist (parser)   util (czyste pomocniki)   scaffold   doctor
```
* **Runner** — każde polecenie przechodzi przez `Runner`: dzięki temu `--dry-run` pokazuje pełny plan, a testy nie potrzebują roota.
* **Etapy** są idempotentne względem `<work>/.state/<etap>.done`; `--resume` pomija zakończone. Bez `--resume` rootfs jest czyszczony.
* **Mounty** (`/proc /sys /dev /run`) aktywne od `packages` do `cleanup`, zdejmowane w `finally`, także po błędzie; `rm -rf` zawsze z `--one-file-system`.
* **Obraz**: squashfs bezpośrednio z drzewa rootfs (`LiveOS/squashfs.img`, dracut `dmsquash-live`), GRUB BIOS (`eltorito.img` = cdboot+core) i UEFI
  (`efiboot.img` FAT), `xorriso -as mkisofs` z hybrydowym MBR i GPT.
* Nowy etap: funkcja w module + wpis w `build.stageNames()` i `build.runStage()`.
