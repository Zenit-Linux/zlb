# packages/zlb.list

```
# komentarz            (także na końcu linii, po spacji)
bash coreutils         # kilka pakietów w linii
@pattern:base          # wzorzec zypper (zypper install -t pattern base)
-systemd               # blokada (zypper addlock) — solver nie zainstaluje
!systemd               # po instalacji: rpm -e --nodeps (gdy trafił jako zależność) + blokada
ffmpeg@packman         # z konkretnego repozytorium (alias z [repos])
[arch=x86_64] ucode-intel
[arch!=aarch64,tag=gui] xorg      # warunki po przecinku = AND, != to negacja
[profile=live] calamares
[init=zenitd] zenit-tools
%include desktop.list  # względem bieżącego pliku, maks. głębokość 8
```
Klucze warunków: `arch`, `profile`, `init`, `tag`. Błędy wskazują `plik:linia`. Pakiet jednocześnie instalowany i blokowany jest błędem.
Wynik sprawdzisz: `zlb list-packages [--profile P --tag T --arch A]`.
