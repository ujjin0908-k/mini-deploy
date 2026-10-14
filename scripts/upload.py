#!/usr/bin/env python3
"""Unpack an uploaded static site (a .zip) for the admin page (P4). Standard library only.

    unpack(zip_path, dest) -> the folder that holds index.html

Every check that can be made from the zip's table of contents runs BEFORE a single file is
written: entry count, sizes, compression ratio, names (no absolute paths, no '..', no '\\',
no control characters, no duplicates even in other letter case), entry types (no links,
devices or FIFOs), no encryption, and never '.env*', '.git', '.npmrc' (deploy.py's rule).
Then only plain files are written (O_EXCL, O_NOFOLLOW, mode 0644), and the real bytes are
counted while writing, so a zip that lies about its sizes is stopped as well.

The table of contents itself is size-checked before Python's zipfile reads it: zipfile
builds an object per entry when it opens a file, so a 50 MB zip of nothing but tiny entries
could otherwise use hundreds of MB of memory before any of our checks ran.

The result is the zip's root, or its one top folder when that is all it holds (what
Windows' "Compress to ZIP file" makes). The caller deploys it with deploy.deploy(), whose
own checks (links, special files, .env, size) run again on the source and on the copy.
Every refusal is an UploadError with a plain reason; a name from the zip appears in it only
cleaned to printable ASCII, and never a file's content.
"""

import os
import re
import stat
import struct
import sys
import zipfile
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import deploy as deploy_mod   # one rule for names that must never be published

MAX_UPLOAD = 50 * 1024 * 1024      # the .zip itself
MAX_ENTRIES = 5000                 # files and folders
MAX_UNPACKED = 200 * 1024 * 1024   # all files together, counted again while writing
MAX_RATIO = 100                    # unpacked : packed, for zips over RATIO_FROM
RATIO_FROM = 1024 * 1024           # tiny sites compress oddly; a bomb is never tiny
# The table of contents (central directory), checked before zipfile parses it. This, not the
# entry count the zip claims, is what bounds memory: zipfile reads entries until this many
# bytes are used up. 5,000 normal entries take about 0.5 MB.
MAX_TOC = 1536 * 1024
MAX_PATH = 1024
MAX_PART = 255
CHUNK = 64 * 1024
TMP_ROOT = None                    # where the admin page unpacks (None = the system temp); tests move it

# What macOS and Windows tools add to zips by themselves: skipped, never written.
SKIPPED_DIRS = ("__MACOSX",)
SKIPPED_FILES = (".DS_Store", "Thumbs.db", "desktop.ini")

DRIVE_RE = re.compile(r"^[A-Za-z]:")
EOCD = b"PK\x05\x06"


class UploadError(Exception):
    pass


def _shown(name):
    """A name from the zip, safe to put in a message or a log line."""
    return re.sub(r"[^\x21-\x7e]", "?", name[:120])


# ---------------------------------------------------------------- before zipfile reads it

def _check_toc(path):
    """Read the end-of-zip record ourselves, the same way zipfile finds it (the last
    signature in the last 64 KB), and refuse a table of contents that is too large to
    parse safely, or the zip64 format (the limits here never need it)."""
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        tail_len = min(size, 20 + 22 + 65535)   # + 20: room for a zip64 locator before the record
        f.seek(size - tail_len)
        tail = f.read(tail_len)
    pos = tail.rfind(EOCD)
    if pos < 0 or len(tail) - pos < 22:
        raise UploadError("this is not a zip file")
    entries, toc_size = struct.unpack("<HI", tail[pos + 10:pos + 16])
    zip64 = pos >= 20 and tail[pos - 20:pos - 16] == b"PK\x06\x07"   # where zipfile looks for it
    if entries == 0xFFFF or toc_size == 0xFFFFFFFF or zip64:
        raise UploadError("this zip uses the large-file format (zip64); zip the site with a standard tool")
    if entries > MAX_ENTRIES:
        raise UploadError(f"the zip has more than {MAX_ENTRIES} files and folders")
    if toc_size > MAX_TOC:
        raise UploadError(f"the zip's list of files is larger than {MAX_TOC / 2**20:g} MB")


# ---------------------------------------------------------------- one entry

def _parts(name):
    """'css/site.css' -> (['css', 'site.css'], False); 'img/' -> (['img'], True)."""
    if not name or len(name) > MAX_PATH:
        raise UploadError(f"a name in the zip is empty or too long: {_shown(name)}")
    if "\\" in name:
        raise UploadError(f"a name in the zip uses '\\': {_shown(name)} (zip it again with a standard tool)")
    if any(ord(c) < 32 or ord(c) == 127 for c in name):
        raise UploadError(f"a name in the zip has control characters: {_shown(name)}")
    if name.startswith("/") or DRIVE_RE.match(name):
        raise UploadError(f"a name in the zip is an absolute path: {_shown(name)}")
    is_dir = name.endswith("/")
    parts = name[:-1].split("/") if is_dir else name.split("/")
    for p in parts:
        if p in ("", ".", ".."):
            raise UploadError(f"a path in the zip points outside the site or is malformed: {_shown(name)}")
        if len(p.encode("utf-8", "surrogateescape")) > MAX_PART:
            raise UploadError(f"a name in the zip is too long: {_shown(name)}")
    return parts, is_dir


def _check_kind(info, is_dir):
    """Plain files and folders only. The type comes from the Unix mode bits a zip may carry."""
    name = _shown(info.filename)
    if info.flag_bits & 0x1:
        raise UploadError(f"an entry in the zip is encrypted: {name}")
    if info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
        raise UploadError(f"an entry uses an unusual compression method: {name} (use a standard zip tool)")
    if info.create_system == 0 and info.external_attr & 0x400:   # a Windows link (reparse point)
        raise UploadError(f"the zip contains a link: {name}")
    mode = info.external_attr >> 16
    kind = stat.S_IFMT(mode)
    if kind == 0:
        return            # no Unix type stored (Windows zips): the name says file or folder
    if stat.S_ISLNK(mode):
        raise UploadError(f"the zip contains a link: {name}")
    if kind not in (stat.S_IFREG, stat.S_IFDIR):
        raise UploadError(f"the zip contains a special file (device, FIFO or socket): {name}")
    if stat.S_ISDIR(mode) != is_dir:
        raise UploadError(f"an entry's type does not match its name: {name}")


def _plan(zf):
    """Every check on the table of contents. Returns [(info, parts, is_dir)] to write."""
    infos = zf.infolist()
    if len(infos) > MAX_ENTRIES:   # _check_toc read the count from the end record; this is the real one
        raise UploadError(f"the zip has more than {MAX_ENTRIES} files and folders")
    plan, seen, total, packed = [], set(), 0, 0
    for info in infos:
        parts, is_dir = _parts(info.filename)
        if parts[0] in SKIPPED_DIRS or (not is_dir and parts[-1] in SKIPPED_FILES):
            continue
        _check_kind(info, is_dir)
        for p in parts:
            if deploy_mod._forbidden(p.lower()):   # .ENV is refused as well as .env
                raise UploadError(f"the zip contains {_shown(p)!r}, which must never be published")
        key = "/".join(parts).lower()
        if key in seen:
            raise UploadError(f"a name is in the zip twice (maybe in other letter case): {_shown(info.filename)}")
        seen.add(key)
        if not is_dir:
            total += info.file_size
            packed += info.compress_size
            if total > MAX_UNPACKED:
                raise UploadError(f"the site would be larger than {MAX_UNPACKED // 2**20} MB unpacked")
        plan.append((info, parts, is_dir))
    if not any(not is_dir for _, _, is_dir in plan):
        raise UploadError("the zip has no files")
    # A file and a folder may not share a name ('a' as a file and 'a/b' inside it).
    files = {"/".join(parts).lower() for _, parts, is_dir in plan if not is_dir}
    for _, parts, _ in plan:
        for n in range(1, len(parts)):
            if "/".join(parts[:n]).lower() in files:
                raise UploadError(f"a name is used both as a file and as a folder: {_shown('/'.join(parts[:n]))}")
    if total > RATIO_FROM and total > MAX_RATIO * max(packed, 1):
        raise UploadError(f"the zip unpacks to more than {MAX_RATIO} times its size (a zip bomb?)")
    return plan


# ---------------------------------------------------------------- writing

def _make_dirs(dest, parts):
    folder = dest
    for p in parts:
        folder = folder / p
        try:
            os.mkdir(folder, 0o755)
            os.chmod(folder, 0o755)        # the service's umask would make it 0700
        except FileExistsError:
            pass
        if not stat.S_ISDIR(os.lstat(folder).st_mode):   # nothing here ever writes a link
            raise UploadError(f"a folder in the zip clashes with a file: {_shown(p)}")
    return folder


def _write(zf, info, target, written):
    """One plain file, bytes counted against its own size and the total. Returns the new total."""
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    with os.fdopen(fd, "wb") as out:
        os.fchmod(out.fileno(), 0o644)     # never setuid, never executable, whatever the zip says
        own = 0
        with zf.open(info) as src:
            while True:
                chunk = src.read(CHUNK)
                if not chunk:
                    break
                own += len(chunk)
                written += len(chunk)
                if own > info.file_size or written > MAX_UNPACKED:
                    raise UploadError("the zip holds more data than it says (a zip bomb?)")
                out.write(chunk)
    return written


def _site_root(dest):
    if (dest / "index.html").is_file():
        return dest
    top = list(dest.iterdir())
    if len(top) == 1 and not top[0].is_symlink() and top[0].is_dir() and (top[0] / "index.html").is_file():
        return top[0]
    raise UploadError("index.html is missing: put it at the top of the zip, or zip the site's folder itself")


def unpack(zip_path, dest):
    """Check the zip at zip_path, write it into the empty folder dest, return the site's folder."""
    dest = Path(dest)
    if any(dest.iterdir()):
        raise UploadError("internal: the unpack folder is not empty")
    try:
        _check_toc(zip_path)
        with zipfile.ZipFile(zip_path) as zf:
            plan = _plan(zf)
            written = 0
            for info, parts, is_dir in plan:
                folder = _make_dirs(dest, parts if is_dir else parts[:-1])
                if not is_dir:
                    written = _write(zf, info, folder / parts[-1], written)
    except UploadError:
        raise
    except (zipfile.BadZipFile, zlib.error, EOFError, NotImplementedError, UnicodeError,
            ValueError, RuntimeError, struct.error) as e:
        raise UploadError(f"the zip is damaged or not a zip ({type(e).__name__})")
    except OSError as e:
        raise UploadError(f"could not unpack the zip ({type(e).__name__}; is the disk full?)")
    return _site_root(dest)
