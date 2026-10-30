#!/usr/bin/env python3
"""Build the Linux VM's initramfs from Alpine packages, without root or Docker.

    mkrootfs.py --arch x86_64|aarch64 --agent AGENT --out initramfs.img
                [--alpine 3.22] [--cache DIR] [PACKAGE ...]

Resolves the packages and their dependencies from Alpine's APKINDEX,
downloads them (cached by file name), and writes a gzip-compressed newc cpio
straight from the packages' tar streams, keeping their owners and modes:
nothing is extracted, so no root is needed to give files to root. Busybox's
applet links come from the busybox-paths list Alpine's package carries. The
agent becomes /init.
"""
import argparse
import gzip
import io
import os
import sys
import tarfile
import time
import urllib.request

MIRROR = os.environ.get("ALPINE_MIRROR", "https://dl-cdn.alpinelinux.org/alpine")
DEFAULT_PACKAGES = [
    "alpine-baselayout", "alpine-release", "busybox", "busybox-binsh", "musl",
    "ca-certificates-bundle", "runc", "iptables", "ip6tables",
]


def fetch(url, path):
    if os.path.exists(path):
        return path
    tmp = path + ".part"
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=60) as r, open(tmp, "wb") as f:
                f.write(r.read())
            os.replace(tmp, path)
            return path
        except Exception as e:  # noqa: BLE001 - retry any download error
            if attempt == 2:
                raise SystemExit(f"download {url}: {e}")
            time.sleep(2)
    return path


def read_index(path):
    """APKINDEX entries as dicts of their one-letter fields."""
    with tarfile.open(path, "r:gz") as t:
        text = t.extractfile("APKINDEX").read().decode()
    entries = []
    for block in text.split("\n\n"):
        e = {}
        for line in block.splitlines():
            if len(line) > 2 and line[1] == ":":
                e[line[0]] = line[2:]
        if "P" in e:
            entries.append(e)
    return entries


def strip_version(dep):
    for op in ("<=", ">=", "~", "=", "<", ">"):
        if op in dep:
            return dep.split(op, 1)[0]
    return dep


def resolve(index, wanted):
    by_name, providers = {}, {}
    for e in index:
        by_name[e["P"]] = e
        for p in e.get("p", "").split():
            providers.setdefault(strip_version(p), e)
    out, todo = {}, list(wanted)
    while todo:
        name = todo.pop()
        if name.startswith("!"):
            continue
        e = by_name.get(name) or providers.get(name)
        if e is None:
            raise SystemExit(f"no Alpine package provides {name}")
        if e["P"] in out:
            continue
        out[e["P"]] = e
        todo.extend(strip_version(d) for d in e.get("D", "").split())
    return out


class Cpio:
    """A newc archive writer."""

    def __init__(self, f):
        self.f, self.ino, self.seen = f, 1, set()

    def _entry(self, name, mode, uid, gid, mtime, data=b"", nlink=1):
        name = name.lstrip("./") or "."
        if name in self.seen:
            return
        self.seen.add(name)
        nameb = name.encode() + b"\0"
        hdr = "070701" + "".join(f"{v:08X}" for v in (
            self.ino, mode, uid, gid, nlink, int(mtime), len(data), 0, 0, 0, 0, len(nameb), 0))
        self.ino += 1
        self.f.write(hdr.encode() + nameb)
        self.f.write(b"\0" * ((4 - (110 + len(nameb)) % 4) % 4))
        self.f.write(data)
        self.f.write(b"\0" * ((4 - len(data) % 4) % 4))

    def dir(self, name, mode=0o755, uid=0, gid=0, mtime=0):
        self._entry(name, 0o040000 | mode, uid, gid, mtime, nlink=2)

    def file(self, name, data, mode=0o644, uid=0, gid=0, mtime=0):
        self._entry(name, 0o100000 | mode, uid, gid, mtime, data)

    def symlink(self, name, target, uid=0, gid=0, mtime=0):
        self._entry(name, 0o120777, uid, gid, mtime, target.encode())

    def trailer(self):
        self._entry("TRAILER!!!", 0, 0, 0, 0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arch", required=True, choices=["x86_64", "aarch64"])
    ap.add_argument("--alpine", default="3.22")
    ap.add_argument("--agent", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--cache", default=os.path.expanduser("~/.cache/linuxvm-alpine"))
    ap.add_argument("packages", nargs="*")
    a = ap.parse_args()

    cache = os.path.join(a.cache, a.alpine, a.arch)
    os.makedirs(cache, exist_ok=True)
    index = []
    for section in ("main", "community"):  # runc is in community
        repo = f"{MIRROR}/v{a.alpine}/{section}/{a.arch}"
        index_path = os.path.join(cache, f"APKINDEX-{section}.tar.gz")
        if os.path.exists(index_path) and time.time() - os.path.getmtime(index_path) > 86400:
            os.remove(index_path)
        for e in read_index(fetch(f"{repo}/APKINDEX.tar.gz", index_path)):
            e["repo"] = repo
            index.append(e)
    pkgs = resolve(index, a.packages or DEFAULT_PACKAGES)

    raw = io.BytesIO()
    cpio = Cpio(raw)
    files = {}      # path -> (data, mode, uid, gid, mtime) for hard links
    links = []      # (path, target) hard links, written as copies
    busybox_paths = []
    for name in sorted(pkgs):
        e = pkgs[name]
        fname = f"{e['P']}-{e['V']}.apk"
        path = fetch(f"{e['repo']}/{fname}", os.path.join(cache, fname))
        # an .apk is three gzip streams (signature, control, data) of one tar
        with gzip.open(path) as g:
            stream = io.BytesIO(g.read())
        with tarfile.open(fileobj=stream, mode="r:", ignore_zeros=True) as t:
            for m in t:
                if m.name.startswith(".") and "/" not in m.name.lstrip("./"):
                    continue  # .PKGINFO, .SIGN.*, install scripts
                if m.isdir():
                    cpio.dir(m.name, m.mode, m.uid, m.gid, m.mtime)
                elif m.issym():
                    cpio.symlink(m.name, m.linkname, m.uid, m.gid, m.mtime)
                elif m.islnk():
                    links.append((m.name, m.linkname))
                elif m.isreg():
                    data = t.extractfile(m).read()
                    files[m.name] = (data, m.mode, m.uid, m.gid, m.mtime)
                    cpio.file(m.name, data, m.mode, m.uid, m.gid, m.mtime)
                    if m.name.endswith("etc/busybox-paths.d/busybox"):
                        busybox_paths = data.decode().split()
    for name, target in links:
        if target in files:
            data, mode, uid, gid, mtime = files[target]
            cpio.file(name, data, mode, uid, gid, mtime)
    # iptables' command names are links an install script makes
    if "usr/sbin/xtables-nft-multi" in files:
        for cmd in ("iptables", "iptables-save", "iptables-restore",
                    "ip6tables", "ip6tables-save", "ip6tables-restore"):
            cpio.symlink(f"usr/sbin/{cmd}", "xtables-nft-multi")
    for p in busybox_paths:
        # /usr/bin/foo -> /bin/busybox
        cpio.symlink(p.lstrip("/"), "/bin/busybox")
    with open(a.agent, "rb") as f:
        cpio.file("init", f.read(), 0o755)
    for d in ("proc", "sys", "dev", "run", "tmp", "host", "hostc", "sysroot"):
        cpio.dir(d)
    cpio.file("etc/hostname", b"airos-linuxvm\n")
    cpio.trailer()

    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with gzip.open(a.out + ".part", "wb", compresslevel=9) as g:
        g.write(raw.getvalue())
    os.replace(a.out + ".part", a.out)
    print(f"{a.out}: {len(pkgs)} packages ({', '.join(sorted(pkgs))})")


if __name__ == "__main__":
    sys.exit(main())
