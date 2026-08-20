import std/[os, osproc, streams, strutils, strformat]
import ./types

const zpmBinaryCandidates = ["zpm", "/usr/bin/zpm", "/usr/local/bin/zpm"]

proc findZpmBinary(): string =
  for c in zpmBinaryCandidates:
    if c.contains("/"):
      if fileExists(c): return c
    else:
      let found = findExe(c)
      if found.len > 0: return found
  return ""

proc runZpm(rootfs: string, args: seq[string]): tuple[ok: bool, output: string] =
  let bin = findZpmBinary()
  if bin.len == 0:
    # ---- PLACEHOLDER PATH ------------------------------------------------
    # Real zpm isn't available yet. Simulate success and record intent so
    # `zlb build` still produces a coherent, inspectable image tree.
    let simulated = "[zpm:placeholder] would run: zpm --root " & rootfs & " " & args.join(" ")
    return (true, simulated)
  else:
    let fullArgs = @["--root", rootfs] & args
    let p = startProcess(bin, args = fullArgs, options = {poUsePath, poStdErrToStdOut})
    let output = readAll(p.outputStream)
    let code = p.waitForExit()
    close(p)
    return (code == 0, output)

proc zpmInit*(rootfs: string, zpmKeyList: string): bool =
  ## Bootstraps the base zpm database inside a fresh rootfs, trusting the
  ## keys declared in keys/default.hcl.
  let (ok, output) = runZpm(rootfs, @["init", "--trust-keys", zpmKeyList])
  echo output
  ok

proc zpmInstall*(rootfs: string, packages: seq[string]): bool =
  if packages.len == 0: return true
  let (ok, output) = runZpm(rootfs, @["install", "-y"] & packages)
  echo output
  ok

proc zpmRemove*(rootfs: string, packages: seq[string]): bool =
  if packages.len == 0: return true
  let (ok, output) = runZpm(rootfs, @["remove", "-y"] & packages)
  echo output
  ok

proc zpmSync*(rootfs: string): bool =
  let (ok, output) = runZpm(rootfs, @["sync"])
  echo output
  ok
