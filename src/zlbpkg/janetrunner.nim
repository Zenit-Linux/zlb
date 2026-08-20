import std/[os, osproc, strformat, strtabs]
import ./types

type HookStage* = enum
  hsPrePackages   = "pre-packages"
  hsPostPackages  = "post-packages"
  hsPostOverlay   = "post-overlay"

proc runJanetScript*(scriptPath, rootfs, moduleName, arch, distroName, version: string,
                      stage: HookStage) =
  let janetBin = findExe("janet")
  if janetBin.len == 0:
    raise newException(ZlbError,
      "janet interpreter not found on PATH -- required to run " & scriptPath)

  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  env["ZLB_ROOTFS"] = rootfs
  env["ZLB_STAGE"] = $stage
  env["ZLB_MODULE"] = moduleName
  env["ZLB_ARCH"] = arch
  env["ZLB_DISTRO_NAME"] = distroName
  env["ZLB_VERSION"] = version

  echo &"  -> [janet:{stage}] {moduleName}/scripts/{extractFilename(scriptPath)}"
  let p = startProcess(janetBin, args = @[scriptPath], env = env,
                        options = {poUsePath, poParentStreams})
  let code = p.waitForExit()
  close(p)
  if code != 0:
    raise newException(ZlbError,
      &"Janet hook failed ({code}): {scriptPath}")

proc runModuleHooks*(scripts: seq[string], rootfs, moduleName, arch, distroName, version: string,
                      stage: HookStage) =
  ## By convention, scripts are prefixed NN- and already sorted by
  ## discoverModule(); a script itself decides which stage(s) it wants to
  ## act on by checking the ZLB_STAGE env var, so we simply invoke every
  ## script once per stage and let it no-op when the stage doesn't apply.
  for s in scripts:
    runJanetScript(s, rootfs, moduleName, arch, distroName, version, stage)
