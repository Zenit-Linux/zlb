import std/[os, osproc, streams, strutils, strformat]
import ./types

const zpmBinaryCandidates = ["zpm", "/usr/bin/zpm", "/usr/local/bin/zpm"]

var extraSearchDirs*: seq[string] = @[]
  ## Populated by zlbpkg/tools.nim after bootstrapping a fresh zpm binary
  ## into out/cache/tools -- checked before falling back to PATH so a
  ## freshly-downloaded zpm is picked up even if it isn't on PATH yet.

var allowPlaceholder*: bool = false
  ## v0.2 -- ustawiane raz przez zlbpkg/tools.nim (ensureBuildTools) z
  ## `tools.allow_placeholder` w distro.hcl. Domyślnie FALSE: brak
  ## realnego 'zpm' to TWARDY błąd builda (patrz runZpm), nie cichy
  ## placeholder udający sukces.

proc findZpmBinary(): string =
  for d in extraSearchDirs:
    let c = d / "zpm"
    if fileExists(c): return c
  for c in zpmBinaryCandidates:
    if c.contains("/"):
      if fileExists(c): return c
    else:
      let found = findExe(c)
      if found.len > 0: return found
  return ""

proc entryArg(e: PackageEntry): string =
  ## Serializuje PackageEntry z powrotem do zwartej składni "nazwa ->
  ## backend -> wariant" rozumianej przez zpm (parsePackageSpec w
  ## zpmpkg/orchestrator.nim / building.nim). To jest jedyny punkt
  ## styku między formatem HCL package.list (zlbpkg/modules.nim) a CLI
  ## zpm -- zlb PARSUJE HCL, zpm NIGDY go nie widzi, dostaje tylko ten
  ## zwarty string jako argument pozycyjny.
  result = e.name
  if e.backend.len > 0:
    result &= " -> " & e.backend
    if e.variant.len > 0:
      result &= " -> " & e.variant
  elif e.variant.len > 0:
    # wariant bez jawnego backendu nie ma sensu (backend decyduje o
    # znaczeniu wariantu: branch dla 'own', dystrybucja dla reszty) --
    # to błąd konfiguracji wykrywany już w modules.nim, ale zabezpieczamy
    # się tutaj drugi raz zamiast ciszej wysyłki niepoprawnej składni.
    discard
  if e.description.len > 0:
    result &= " : " & e.description

proc runZpm(args: seq[string]): tuple[ok: bool, output: string] =
  let bin = findZpmBinary()
  if bin.len == 0:
    if not allowPlaceholder:
      # v0.2 -- ZAMYKA lukę "tryb placeholder cicho udaje sukces": brak
      # realnego 'zpm' to teraz TWARDY błąd builda. Wcześniej ta gałąź
      # zwracała (true, "...") niezależnie od tego, czy komenda była
      # 'install kernel' czy 'remove --force cokolwiek' -- czyli `zlb
      # build` mógł "zakończyć się sukcesem" i wyprodukować ISO/OCI z
      # rootfs, w którym w rzeczywistości NIC nie zostało zainstalowane.
      # To jest dokładnie ten rodzaj cichej porażki, którego CI/produkcja
      # nie może sobie pozwolić przeoczyć.
      let msg = "[zpm:FATAL] Nie znaleziono binarki 'zpm' (ani w cache narzędzi, ani na PATH) -- " &
        "przerywam build, ponieważ 'tools.allow_placeholder' NIE jest ustawione na true w distro.hcl. " &
        &"Komenda, która się nie wykonała: zpm {args.join(\" \")}\n" &
        "  Napraw jedno z: (1) upewnij się, że 'tools.auto_fetch = true' i 'tools.zpm_url' wskazuje na " &
        "działający release, (2) zainstaluj 'zpm' ręcznie i dodaj do PATH, (3) jeśli TO ŚWIADOME (np. " &
        "inspekcja drzewa modułów bez realnej instalacji pakietów), dodaj `tools { allow_placeholder = true }` " &
        "do distro.hcl -- każde użycie i tak zostanie głośno ostrzeżone, nie po cichu przemilczane."
      stderr.writeLine(msg)
      return (false, msg)
    # ---- PLACEHOLDER PATH (świadomie włączone: tools.allow_placeholder = true) ----
    let simulated = "[zpm:placeholder] UWAGA: tools.allow_placeholder=true -- SYMULUJĘ (nie wykonuję!): zpm " & args.join(" ")
    stderr.writeLine(simulated)
    return (true, simulated)
  else:
    let p = startProcess(bin, args = args, options = {poUsePath, poStdErrToStdOut})
    let output = readAll(p.outputStream)
    let code = p.waitForExit()
    close(p)
    return (code == 0, output)

proc zpmInit*(rootfs: string, zpmKeyList: string): bool =
  ## Bootstraps the base zpm database inside a fresh rootfs, trusting the
  ## keys declared in keys/default.hcl.
  let (ok, output) = runZpm(@["--root=" & rootfs, "init", "--trust-keys=" & zpmKeyList])
  echo output
  ok

proc zpmInstall*(rootfs: string, packages: seq[PackageEntry], defaultBackend = ""): bool =
  if packages.len == 0: return true
  var args = @["--root=" & rootfs]
  if defaultBackend.len > 0: args.add "--backend=" & defaultBackend
  args.add "install"
  for p in packages: args.add entryArg(p)
  let (ok, output) = runZpm(args)
  echo output
  ok

proc zpmRemove*(rootfs: string, packages: seq[PackageEntry], defaultBackend = ""): bool =
  if packages.len == 0: return true
  var args = @["--root=" & rootfs]
  if defaultBackend.len > 0: args.add "--backend=" & defaultBackend
  args.add "remove"
  for p in packages: args.add entryArg(p)
  let (ok, output) = runZpm(args)
  echo output
  ok

proc zpmSync*(rootfs: string): bool =
  let (ok, output) = runZpm(@["--root=" & rootfs, "sync"])
  echo output
  ok
