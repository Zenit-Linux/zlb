version       = "0.2.0"
author        = "Zenit Linux Developers"
description   = "ZLB - Zenit Linux Builder: ISO/OCI image builder for Zenit Linux"
license       = "GPL-3.0"
srcDir        = "src"
bin           = @["zlb"]
binDir        = "bin"

# Dependencies

requires "nim >= 2.0.0"
requires "hcl_nim >= 0.1"

task buildRelease, "Build optimized release binary":
  exec "nim c -d:release -d:ssl --opt:speed -o:bin/zlb src/zlb.nim"
