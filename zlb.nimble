version       = "0.1.0"
author        = "Zenith Linux Developers"
description   = "ZLB - Zenith Linux Builder: ISO/OCI image builder for Zenith Linux"
license       = "GPL-3.0"
srcDir        = "src"
bin           = @["zlb"]
binDir        = "bin"

# Dependencies

requires "nim >= 2.0.0"

task buildRelease, "Build optimized release binary":
  exec "nim c -d:release -d:ssl --opt:speed -o:bin/zlb src/zlb.nim"
