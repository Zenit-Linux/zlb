# Wybór init i menedżera pakietów

| `init.system` | Co robi zlb | Kernel `init=` | systemd w obrazie |
|---|---|---|---|
| `systemd` | nic — systemd przychodzi z pakietami (dopisz `systemd systemd-sysvcompat` do `zlb.list`) | domyślny | tak |
| `zenitd` | klonuje/buduje zenitd i instaluje jego `scripts/install.sh --zenit` | `/sbin/init` | nie |
| `custom` | instaluje `init.custom.packages`, uruchamia `init.custom.post` w chroot | `init.custom.init_path` | nie, gdy `block_systemd = true` |
| `none` | nic — init dostarczasz w hookach | domyślny | wg listy pakietów |

## Jak zlb pozbywa się systemd (obrazy bez systemd)

Pakiety Tumbleweed mają zależności od `systemd`. Są dwie ścieżki:

1. **`zpm`** (zalecana; `packages.manager = "auto"` wybiera ją, gdy zpm jest w PATH albo pod `zpm.binary`).
   Przed pierwszą instalacją zpm wstrzykuje pakiet-atrapę `zpm-stub-<profil>` (tylko `Provides: systemd = 99999`, `/usr/bin/systemctl`, …) i blokady
   zypper na `systemd` i `systemd-*`. Zależności są spełnione, a systemd nigdy nie trafia do obrazu; baza rpm jest spójna.
   zpm i jego konfiguracja trafiają też do obrazu (`zpm.install_in_image`), więc użytkownik gotowej dystrybucji ma ten sam mechanizm.
2. **Bez zpm** (`packages.manager = "zypper"` albo zpm niedostępny): systemd bywa wciągnięty jako zależność, więc zlb usuwa go po instalacji
   (`rpm -e --nodeps` dla `init.systemd_packages` i wpisów `!pkg` z listy) i blokuje. Działa, ale `zypper verify` w gotowym systemie zgłosi
   niespełnione zależności — dlatego dla obrazów produkcyjnych używaj zpm.

`zlb verify` kończy się błędem, jeśli manifest pakietów (`.packages`) zawiera `systemd` lub `systemd-*` w obrazie, który miał być bez systemd
(biblioteki `libsystemd0`/`libudev1` i `udev` nie są traktowane jako wyciek). To samo ostrzeżenie zlb wypisuje na końcu budowy.

## Warunki w liście pakietów
`[init=zenitd] !systemd`, `[init=custom] …`, `[init=openrc] …` — nazwa to `init.name` albo, gdy puste, `init.system`.

## Własny init krok po kroku
Wzorzec: `zlb new mojdistro --template custom` (przykład z OpenRC; nazwy pakietów i polecenia `post` zweryfikuj we własnym repozytorium).
