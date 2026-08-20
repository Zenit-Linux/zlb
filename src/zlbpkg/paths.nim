import std/os

type ProjectPaths* = object
  root*: string
  outDir*: string
  cacheDir*: string

proc resolveProjectPaths*(root: string): ProjectPaths =
  result.root = root
  result.outDir = root / "out"
  result.cacheDir = result.outDir / "cache"

proc ensureBaseDirs*(p: ProjectPaths) =
  createDir(p.outDir)
  createDir(p.cacheDir)
  createDir(p.cacheDir / "seeds")
  createDir(p.cacheDir / "zpm")
  createDir(p.cacheDir / "work")

proc rootfsDir*(p: ProjectPaths, arch: string): string =
  p.cacheDir / "rootfs" / arch

proc workDir*(p: ProjectPaths, arch: string): string =
  p.cacheDir / "work" / arch

proc stagingDir*(p: ProjectPaths, arch: string): string =
  p.cacheDir / "work" / arch / "staging"

proc ociLayoutDir*(p: ProjectPaths, name: string): string =
  p.outDir / "oci" / name

proc finalPath*(p: ProjectPaths, filename: string): string =
  p.outDir / filename
