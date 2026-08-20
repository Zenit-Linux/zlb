import std/[os, osproc, strutils]
import ./types
import ./hcl

type ZpmRepoKey* = object
  name*: string
  url*: string
  keyId*: string
  pubkey*: string

proc loadZpmTrustStore*(path: string): seq[ZpmRepoKey] =
  result = @[]
  if not fileExists(path):
    return
  let root = parseHcl(readFile(path))
  let repoField = root["repo"]
  if repoField.isNil: return
  let items = if repoField.kind == hkList: repoField.listVal else: @[repoField]
  for item in items:
    result.add ZpmRepoKey(
      name: item.label,
      url: item.getStr("url"),
      keyId: item.getStr("key_id"),
      pubkey: item.getStr("pubkey"),
    )

proc signRelease*(gpgKeyId, dir, sumsFile: string): bool =
  ## Detached-signs out/<...>/SHA256SUMS with the release key. No-ops
  ## (with a warning) if gpg or a key id isn't configured, so local dev
  ## builds don't hard-fail on missing signing keys.
  let gpgBin = findExe("gpg")
  if gpgBin.len == 0 or gpgKeyId.len == 0:
    echo "  ! skipping release signature (gpg or keys.gpg_key_id not configured)"
    return true
  let args = @["--batch", "--yes", "--local-user", gpgKeyId,
               "--output", sumsFile & ".asc", "--detach-sign", sumsFile]
  let (output, code) = execCmdEx(gpgBin & " " & args.join(" "))
  echo output
  code == 0
