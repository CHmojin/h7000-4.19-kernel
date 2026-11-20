#!/usr/bin/env python3
"""Assemble an Android boot image (header v0/v1) from Image.gz + appended DTB.

Reproduces the layout used by the stock BBK S5 (H7000) boot image:
  header v1, 4096-byte pages, kernel = Image.gz + appended dtb (Image.gz-dtb).
"""
import argparse, hashlib, os, struct


def align(n, p):
    return (n + p - 1) // p * p


def build(kernel, ramdisk, cmdline, out, page_size=4096, kernel_addr=0x8000,
          ramdisk_addr=0x1000000, tags_addr=0x100, os_version=0x16000182,
          header_version=1, name=b''):
    assert len(kernel) > 0
    hdr = bytearray(4096)
    hdr[0:8] = b'ANDROID!'
    struct.pack_into('<10I', hdr, 8,
                     len(kernel), kernel_addr,
                     len(ramdisk), ramdisk_addr,
                     0, 0,
                     tags_addr, page_size,
                     header_version, os_version)
    hdr[48:64] = name.ljust(16, b'\0')[:16]
    hdr[64:576] = cmdline.encode()[:512].ljust(512, b'\0')
    # id: sha1 over kernel+size, ramdisk+size, second+size (as mkbootimg does)
    sha = hashlib.sha1()
    sha.update(kernel + struct.pack('<I', len(kernel)))
    sha.update(ramdisk + struct.pack('<I', len(ramdisk)))
    hdr[576:608] = sha.digest() + b'\0' * (32 - sha.digest_size)
    if header_version >= 1:
        struct.pack_into('<IQI', hdr, 1632, 0, 0, 1648)
    if header_version >= 2:
        struct.pack_into('<IQ', hdr, 1648, 0, 0)

    body = bytearray()
    body += hdr[:align(1648 if header_version >= 1 else 1632, page_size)]
    body += kernel
    body += b'\0' * (align(len(kernel), page_size) - len(kernel))
    body += ramdisk
    body += b'\0' * (align(len(ramdisk), page_size) - len(ramdisk))
    with open(out, 'wb') as f:
        f.write(body)
    return len(body)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--kernel', required=True, help='Image.gz (no dtb)')
    ap.add_argument('--dtb', default=None, help='dtb appended to Image.gz')
    ap.add_argument('--ramdisk', required=True)
    ap.add_argument('--cmdline', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--os-version', type=lambda x: int(x, 0), default=0x16000182)
    ap.add_argument('--pagesize', type=int, default=4096)
    ap.add_argument('--kernel-addr', type=lambda x: int(x, 0), default=0x8000)
    ap.add_argument('--ramdisk-addr', type=lambda x: int(x, 0), default=0x1000000)
    ap.add_argument('--header-version', type=int, default=1)
    a = ap.parse_args()

    k = open(a.kernel, 'rb').read()
    if a.dtb:
        dtb = open(a.dtb, 'rb').read()
        assert dtb[:4] == b'\xd0\x0d\xfe\xed', 'dtb magic missing'
        k = k + dtb
        print(f'Image.gz {len(k)-len(dtb)} B + dtb {len(dtb)} B = {len(k)} B')
    r = open(a.ramdisk, 'rb').read()
    n = build(k, r, a.cmdline, a.out, page_size=a.pagesize,
              kernel_addr=a.kernel_addr, ramdisk_addr=a.ramdisk_addr,
              os_version=a.os_version, header_version=a.header_version)
    print(f'boot image written: {a.out} ({n} bytes)')


if __name__ == '__main__':
    main()
