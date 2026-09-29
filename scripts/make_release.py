#!/usr/bin/env python3
"""Генерация Release-файла APT-репозитория с полями, которые требует Sileo."""
import hashlib
import os
import sys
import time
from email.utils import formatdate

DIST = sys.argv[1] if len(sys.argv) > 1 else "repo"
FILES = ["Packages", "Packages.gz", "Packages.bz2"]

entries = {}
for alg in ("md5", "sha1", "sha256"):
    entries[alg] = []
    for f in FILES:
        p = os.path.join(DIST, f)
        h = hashlib.new(alg)
        with open(p, "rb") as fh:
            h.update(fh.read())
        entries[alg].append((h.hexdigest(), os.path.getsize(p), f))

lines = [
    "Origin: listrrise",
    "Label: listrrise",
    "Suite: stable",
    "Version: 1.0",
    "Codename: ios",
    "Date: " + formatdate(timeval=None, localtime=False, usegmt=True),
    "Architectures: iphoneos-arm iphoneos-arm64",
    "Components: main",
    "Description: listrrise repo (dinapenis, iOS 12-15)",
]
for alg, label in (("md5", "MD5Sum"), ("sha1", "SHA1"), ("sha256", "SHA256")):
    lines.append(label + ":")
    for digest, size, f in entries[alg]:
        lines.append(f" {digest} {size:16d} {f}")

with open(os.path.join(DIST, "Release"), "w") as fh:
    fh.write("\n".join(lines) + "\n")
print("Release written")
