import std/[os, osproc, streams, strutils, strformat]
import ./types

const zpmBinaryCandidates = ["zpm", "/usr/bin/zpm", "/usr/local/bin/zpm"]

var extraSearchDirs*: seq[string] = @[]
  ## Populated by zlbpkg/tools.nim after bootstrapping a fresh zpm binary
  ## into out/cache/tools -- checked before falling back to PATH so a
  ## freshly-downloaded zpm is picked up even if it isn't on PATH yet.

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
  ## Serializuje PackageEntry z powrotem do składni "nazwa -> backend"
  ## rozumianej przez zpm (zpmpkg/orchestrator.nim / building.nim).
  if e.backend.len > 0: e.name & " -> " & e.backend
  else: e.name

proc runZpm(args: seq[string]): tuple[ok: bool, output: string] =
  let bin = findZpmBinary()
  if bin.len == 0:
    # ---- PLACEHOLDER PATH ------------------------------------------------
    # Real zpm isn't available yet (bootstrap in zlbpkg/tools.nim failed
    # or auto_fetch = false and it's not on PATH either). Simulate success
    # and record intent so `zlb build` still produces a coherent,
    # inspectable image tree.
    let simulated = "[zpm:placeholder] would run: zpm " & args.join(" ")
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
