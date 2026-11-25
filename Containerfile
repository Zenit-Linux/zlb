# Środowisko budujące: openSUSE Tumbleweed z narzędziami zlb.
# podman build -t zlb-builder .   &&   podman run --rm --privileged -v "$PWD":/work -w /work zlb-builder zlb build
FROM registry.opensuse.org/opensuse/tumbleweed:latest
RUN zypper --non-interactive install --no-recommends \
        bash coreutils util-linux tar zstd gzip xz git curl gpg2 rpm zypper \
        rpm-build qemu-x86 qemu-ovmf-x86_64 busybox-static squashfs xorriso mtools dosfstools grub2 grub2-i386-pc grub2-x86_64-efi shim \
    && zypper clean -a
# zlb, zpm i z# dostarcz własną drogą (binarki standalone):
COPY zlb zpm /usr/local/bin/
WORKDIR /work
