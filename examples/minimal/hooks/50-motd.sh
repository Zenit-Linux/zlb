#!/bin/sh
set -eu
# przykładowy hook: znacznik wersji obrazu
echo "$ZLB_DISTRO_NAME $ZLB_VERSION" > /etc/zlb-release
