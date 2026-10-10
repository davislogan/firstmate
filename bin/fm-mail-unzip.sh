#!/usr/bin/env bash
# Safe zip extractor for mail-mode attachments (untrusted input).
#
# Usage: fm-mail-unzip.sh <zip-file> <dest-dir>
#   Validates the WHOLE archive before writing anything, then extracts it into
#   <dest-dir> (which must not exist yet) via a sibling temp dir and an atomic
#   rename, so a refused or failed archive leaves nothing behind.
#   Refuses the archive (exit 3, nothing written) when any of these hold:
#     - more than FM_MAIL_ZIP_MAX_ENTRIES entries (default 200, nested included)
#     - more than FM_MAIL_ZIP_MAX_BYTES uncompressed bytes (default 200 MiB,
#       declared or actually streamed, nested included)
#     - an entry compression ratio above FM_MAIL_ZIP_MAX_RATIO (default 100:1)
#     - an absolute path, a drive letter, a ".." component, a control character,
#       or a duplicate path
#     - a symlink or other non-regular entry, or an encrypted entry
#   One nesting level: a .zip inside the archive is validated against the same
#   shared budget and extracted into "<inner path>.unzipped/" instead of being
#   written as a file; a zip nested inside THAT is skipped (not written) and
#   listed under "skipped".
#   Files are written 0600 and dirs 0700; nothing is ever executed.
#   Prints one JSON summary line: {"ok":true,"files":N,"bytes":B,"skipped":[...]}
#   on success, or {"ok":false,"reason":"..."} on refusal (exit 3).
#   Exit 2 is a usage error; exit 1 is a missing python3 or unreadable input.
# Needs python3 (stdlib zipfile only); there is no `unzip` dependency.
set -u

if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
  echo "usage: fm-mail-unzip.sh <zip-file> <dest-dir>" >&2
  exit 2
fi
command -v python3 >/dev/null 2>&1 || { echo "fm-mail-unzip: python3 not found" >&2; exit 1; }
[ -f "$1" ] || { echo "fm-mail-unzip: no such file: $1" >&2; exit 1; }
if [ -e "$2" ] || [ -L "$2" ]; then
  echo "fm-mail-unzip: destination already exists: $2" >&2
  exit 2
fi

exec python3 -I - "$1" "$2" \
  "${FM_MAIL_ZIP_MAX_ENTRIES:-200}" \
  "${FM_MAIL_ZIP_MAX_BYTES:-209715200}" \
  "${FM_MAIL_ZIP_MAX_RATIO:-100}" <<'PY'
import io, json, os, shutil, stat, sys, tempfile, zipfile

src, dest = sys.argv[1], sys.argv[2]
def num(v, d):
    try:
        n = int(v)
        return n if n > 0 else d
    except ValueError:
        return d
MAX_ENTRIES = num(sys.argv[3], 200)
MAX_BYTES = num(sys.argv[4], 209715200)
MAX_RATIO = num(sys.argv[5], 100)

class Refuse(Exception):
    pass

def is_zip_name(name):
    return name.lower().endswith(".zip")

def clean_parts(name):
    n = name.replace("\\", "/")
    if any(ord(c) < 32 or ord(c) == 127 for c in n):
        raise Refuse("control character in entry name")
    if n.startswith("/") or (len(n) >= 2 and n[1] == ":"):
        raise Refuse("absolute path entry: %s" % name)
    parts = [p for p in n.split("/") if p not in ("", ".")]
    if any(p == ".." for p in parts):
        raise Refuse("parent-directory entry: %s" % name)
    if not parts:
        raise Refuse("empty entry name")
    return parts, n.endswith("/")

budget = {"entries": 0, "bytes": 0}
skipped = []

def plan(zf, prefix, depth):
    """Validate every entry; return a list of (kind, parts, info, zf, sub)."""
    items, seen = [], set()
    for info in zf.infolist():
        budget["entries"] += 1
        if budget["entries"] > MAX_ENTRIES:
            raise Refuse("too many entries (limit %d)" % MAX_ENTRIES)
        parts, is_dir = clean_parts(info.filename)
        key = "/".join(prefix + parts).lower()
        if key in seen:
            raise Refuse("duplicate entry: %s" % info.filename)
        seen.add(key)
        if info.flag_bits & 0x1:
            raise Refuse("encrypted entry: %s" % info.filename)
        mode = (info.external_attr >> 16) & 0o170000
        if mode and mode not in (stat.S_IFREG, stat.S_IFDIR):
            raise Refuse("symlink or special entry: %s" % info.filename)
        if is_dir or info.is_dir():
            items.append(("dir", prefix + parts, None, None, None))
            continue
        budget["bytes"] += info.file_size
        if budget["bytes"] > MAX_BYTES:
            raise Refuse("archive too large uncompressed (limit %d bytes)" % MAX_BYTES)
        if info.file_size > 0:
            if info.compress_size <= 0 or info.file_size / info.compress_size > MAX_RATIO:
                raise Refuse("compression ratio above %d:1: %s" % (MAX_RATIO, info.filename))
        if is_zip_name(parts[-1]):
            if depth >= 1:
                skipped.append({"name": "/".join(prefix + parts), "reason": "nested archive beyond one level"})
                continue
            data = read_capped(zf, info)
            try:
                inner = zipfile.ZipFile(io.BytesIO(data))
            except zipfile.BadZipFile:
                raise Refuse("corrupt nested archive: %s" % info.filename)
            sub_prefix = prefix + parts[:-1] + [parts[-1] + ".unzipped"]
            items.append(("dir", sub_prefix, None, None, None))
            items.extend(plan(inner, sub_prefix, depth + 1))
            continue
        items.append(("file", prefix + parts, info, zf, None))
    return items

def read_capped(zf, info):
    out = io.BytesIO()
    with zf.open(info) as fh:
        while True:
            chunk = fh.read(65536)
            if not chunk:
                break
            out.write(chunk)
            if out.tell() > info.file_size:
                raise Refuse("entry larger than declared: %s" % info.filename)
    return out.getvalue()

def main():
    try:
        outer = zipfile.ZipFile(src)
    except (zipfile.BadZipFile, OSError) as e:
        raise Refuse("not a readable zip archive")
    items = plan(outer, [], 0)
    parent = os.path.dirname(os.path.abspath(dest)) or "."
    os.makedirs(parent, mode=0o700, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix=".fm-mail-unzip.", dir=parent)
    written = files = 0
    try:
        for kind, parts, info, zf, _ in items:
            target = os.path.join(tmp, *parts)
            if kind == "dir":
                os.makedirs(target, mode=0o700, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(target), mode=0o700, exist_ok=True)
            fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
            n = 0
            with os.fdopen(fd, "wb") as out, zf.open(info) as fh:
                while True:
                    chunk = fh.read(65536)
                    if not chunk:
                        break
                    n += len(chunk)
                    written += len(chunk)
                    if n > info.file_size or written > MAX_BYTES:
                        raise Refuse("entry larger than declared: %s" % info.filename)
                    out.write(chunk)
            files += 1
        os.rename(tmp, dest)
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    print(json.dumps({"ok": True, "files": files, "bytes": written, "skipped": skipped}))

try:
    main()
except Refuse as e:
    print(json.dumps({"ok": False, "reason": str(e)}))
    sys.exit(3)
except (zipfile.BadZipFile, zipfile.LargeZipFile, OSError, RuntimeError, EOFError, NotImplementedError, ValueError) as e:
    print(json.dumps({"ok": False, "reason": "extraction failed: %s: %s" % (type(e).__name__, str(e)[:200])}))
    sys.exit(3)
PY
