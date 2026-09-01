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

# NAPRAWIONE: `-d:ssl` usunięte -- `zlbpkg/tools.nim` pobiera `zpm` przez
# podproces `curl`/`wget`, NIE `std/httpclient`, więc zlb nie potrzebuje
# OpenSSL do zbudowania ani uruchomienia. Trzymanie `-d:ssl` tutaj tylko
# wymuszało niepotrzebną zależność od OpenSSL na maszynie budującej i było
# źródłem błędu "SSL support is not available (...) Compile with -d:ssl to
# enable." u użytkowników bez niego -- patrz komentarz w tools.nim i
# build.janet dla pełnego wyjaśnienia. Zobacz `janet build.janet <task>`
# (preferowany sposób budowania) dla odpowiednika bez nimble.
task buildRelease, "Build optimized release binary":
  exec "nim c -d:release --opt:speed -o:bin/zlb src/zlb.nim"
