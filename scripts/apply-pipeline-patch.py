#!/usr/bin/env python3
"""Check/apply the pinned cutandrun syntax repair. Never fetches pipeline assets."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

MANIFEST = Path(__file__).resolve().parents[1] / "patches/cutandrun-3.2.2.json"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def patch(root, manifest, apply=False):
    root = Path(root).resolve(strict=True)
    revision = subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
    ).strip()
    if revision != manifest["revision"]:
        raise ValueError("HEAD is not the pinned cutandrun 3.2.2 commit; refusing")
    target = root / manifest["path"]
    if target.is_symlink() or target.resolve(strict=True) != target:
        raise ValueError("patch target has a symlink component; refusing")
    before = target.read_bytes()
    actual = digest(before)
    if actual == manifest["after_sha256"]:
        return "already-applied"
    if actual != manifest["before_sha256"]:
        raise ValueError("target preimage differs from the pinned upstream file; refusing")
    old, new = manifest["old"].encode(), manifest["new"].encode()
    if before.count(old) != manifest["occurrences"]:
        raise ValueError("unexpected replacement count")
    after = before.replace(old, new)
    if digest(after) != manifest["after_sha256"]:
        raise ValueError("patched content does not match the manifest")
    if not apply:
        return "applicable"
    # Publish one complete file. Recheck the preimage immediately before replacing.
    mode = target.stat().st_mode & 0o777
    fd, temp = tempfile.mkstemp(prefix=".bioinfo-patch-", dir=target.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(after)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp, mode)
        if target.is_symlink() or target.read_bytes() != before:
            raise ValueError("target changed during patch preparation; refusing")
        os.replace(temp, target)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)
    return "applied"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pipeline_dir", type=Path, help="explicit nf-core/cutandrun checkout")
    parser.add_argument("--apply", action="store_true", help="write the verified two-line repair")
    args = parser.parse_args()
    try:
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        print(json.dumps({"patch": manifest["id"], "result": patch(
            args.pipeline_dir, manifest, args.apply)}))
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        print(f"patch refused: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
