import std/[os, osproc, times, json, strformat, strutils]
import ./types
import ./paths
import ./manifest

proc sha256File(path: string): string =
  ## Shells out to sha256sum rather than pulling in a crypto dep -- it's
  ## on every Linux box ZLB targets anyway.
  let output = execProcess("sha256sum", args = @[path], options = {poUsePath})
  output.split(' ')[0].strip()

proc fileSize(path: string): BiggestInt = getFileSize(path)

proc blobPath(layoutDir, digest: string): string =
  layoutDir / "blobs" / "sha256" / digest

proc addBlob(layoutDir, srcPath: string): tuple[digest: string, size: BiggestInt] =
  createDir(layoutDir / "blobs" / "sha256")
  let digest = sha256File(srcPath)
  let dst = blobPath(layoutDir, digest)
  if not fileExists(dst):
    copyFileWithPermissions(srcPath, dst)
  (digest, fileSize(dst))

proc tarRootfs(rootfs, outTarGz: string) =
  createDir(parentDir(outTarGz))
  let tarBin = findExe("tar")
  if tarBin.len == 0:
    raise newException(ZlbError, "'tar' not found on PATH, required to build OCI layers")
  let p = startProcess(tarBin,
    args = @["-C", rootfs, "-czf", outTarGz, "."],
    options = {poUsePath, poParentStreams})
  let code = p.waitForExit()
  close(p)
  if code != 0:
    raise newException(ZlbError, "tar failed while building OCI layer")

proc buildOciImage*(p: ProjectPaths, m: Manifest, arch: string) =
  let rootfs = p.rootfsDir(arch)
  if not dirExists(rootfs):
    raise newException(ZlbError, &"no staged rootfs for {arch} at {rootfs} -- run 'zlb build rootfs' first")

  let name = expand(m.oci.output, m, arch)
  let layoutDir = p.ociLayoutDir(name)
  removeDir(layoutDir)
  createDir(layoutDir / "blobs" / "sha256")

  echo &"==> [{arch}] tarring rootfs layer"
  let layerTar = p.workDir(arch) / "layer.tar.gz"
  tarRootfs(rootfs, layerTar)
  let (layerDigest, layerSize) = addBlob(layoutDir, layerTar)

  let createdAt = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  let fullTag = &"{m.oci.registry}/{m.oci.repository}:{expand(m.oci.tag, m, arch)}"

  echo &"==> [{arch}] writing image config"
  let config = %*{
    "created": createdAt,
    "architecture": arch,
    "os": "linux",
    "config": {
      "Labels": {
        "org.zenitlinux.distro": m.distro.name,
        "org.zenitlinux.version": m.distro.version,
        "org.zenitlinux.codename": m.distro.codename,
      },
      "Cmd": ["/bin/sh"]
    },
    "rootfs": {
      "type": "layers",
      "diff_ids": [&"sha256:{layerDigest}"]
    },
    "history": [{
      "created": createdAt,
      "created_by": "zlb build oci",
      "comment": &"{m.distro.name} {m.distro.version} ({m.distro.codename})"
    }]
  }
  let configPath = p.workDir(arch) / "config.json"
  writeFile(configPath, $config)
  let (configDigest, configSize) = addBlob(layoutDir, configPath)

  echo &"==> [{arch}] writing manifest + index"
  let imageManifest = %*{
    "schemaVersion": 2,
    "mediaType": "application/vnd.oci.image.manifest.v1+json",
    "config": {
      "mediaType": "application/vnd.oci.image.config.v1+json",
      "digest": &"sha256:{configDigest}",
      "size": configSize
    },
    "layers": [{
      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
      "digest": &"sha256:{layerDigest}",
      "size": layerSize
    }],
    "annotations": {
      "org.opencontainers.image.title": m.distro.name,
      "org.opencontainers.image.version": m.distro.version,
      "org.opencontainers.image.ref.name": fullTag
    }
  }
  let manifestPath = p.workDir(arch) / "manifest.json"
  writeFile(manifestPath, $imageManifest)
  let (manifestDigest, manifestSize) = addBlob(layoutDir, manifestPath)

  let index = %*{
    "schemaVersion": 2,
    "mediaType": "application/vnd.oci.image.index.v1+json",
    "manifests": [{
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": &"sha256:{manifestDigest}",
      "size": manifestSize,
      "platform": {"architecture": arch, "os": "linux"},
      "annotations": {"org.opencontainers.image.ref.name": fullTag}
    }]
  }
  writeFile(layoutDir / "index.json", $index)
  writeFile(layoutDir / "oci-layout", $(%*{"imageLayoutVersion": "1.0.0"}))

  echo &"==> [{arch}] OCI image ready: {layoutDir}  (tag: {fullTag})"
  echo &"    push with: skopeo copy oci:{layoutDir} docker://{fullTag}"
