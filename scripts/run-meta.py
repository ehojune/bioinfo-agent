#!/usr/bin/env python3
"""Create or validate run evidence snapshots using only the Python standard library."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import re
import sys

SCHEMA = Path(__file__).resolve().parents[1] / "schemas/run-meta.schema.json"


def pairs_unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path):
    def invalid_constant(value):
        raise ValueError(f"non-finite JSON number: {value}")
    return json.loads(Path(path).read_text(encoding="utf-8"),
                      object_pairs_hook=pairs_unique, parse_constant=invalid_constant)


def check_schema(value, schema, root, location="$"):
    """Validate the deliberately small schema dialect used by this contract.

    This is not a general-purpose JSON Schema implementation. Unsupported keywords
    fail closed so adding a schema feature cannot silently weaken validation.
    """
    known = {"$schema", "$id", "$defs", "$ref", "title", "description", "type", "enum",
             "required", "properties", "additionalProperties", "items", "minItems",
             "minLength", "pattern", "minimum", "format"}
    unsupported = set(schema) - known
    if unsupported:
        raise ValueError(f"unsupported schema keywords: {sorted(unsupported)}")
    if "$ref" in schema:
        ref = schema["$ref"]
        if not ref.startswith("#/$defs/"):
            raise ValueError("only local $defs schema references are supported")
        check_schema(value, root["$defs"][ref[len("#/$defs/"):]], root, location)
    type_checks = {
        "null": lambda v: v is None,
        "object": lambda v: isinstance(v, dict),
        "array": lambda v: isinstance(v, list),
        "string": lambda v: isinstance(v, str),
        "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
        "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool)
        and (not isinstance(v, float) or math.isfinite(v)),
        "boolean": lambda v: isinstance(v, bool),
    }
    if "type" in schema:
        expected = schema["type"]
        expected = [expected] if isinstance(expected, str) else expected
        if not any(type_checks[t](value) for t in expected):
            raise ValueError(f"{location}: expected {expected}")
    if "enum" in schema and value not in schema["enum"]:
        raise ValueError(f"{location}: unsupported value {value!r}")
    if isinstance(value, dict):
        missing = set(schema.get("required", [])) - set(value)
        if missing:
            raise ValueError(f"{location}: missing {sorted(missing)}")
        props = schema.get("properties", {})
        if schema.get("additionalProperties") is False and set(value) - set(props):
            raise ValueError(f"{location}: unexpected properties {sorted(set(value) - set(props))}")
        for key, item in value.items():
            if key in props:
                check_schema(item, props[key], root, f"{location}.{key}")
    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            raise ValueError(f"{location}: too few items")
        for index, item in enumerate(value):
            if "items" in schema:
                check_schema(item, schema["items"], root, f"{location}[{index}]")
    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0):
            raise ValueError(f"{location}: empty string")
        if "pattern" in schema:
            pattern = schema["pattern"]
            match = re.fullmatch if pattern.startswith("^") and pattern.endswith("$") else re.search
            if not match(pattern, value):
                raise ValueError(f"{location}: invalid format")
        if schema.get("format") == "date-time":
            try:
                parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
                if parsed.tzinfo is None or "T" not in value:
                    raise ValueError("timezone required")
            except ValueError as exc:
                raise ValueError(f"{location}: invalid timestamp") from exc
        elif "format" in schema:
            raise ValueError(f"unsupported format: {schema['format']}")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if (isinstance(value, float) and not math.isfinite(value)) or value < schema.get("minimum", -math.inf):
            raise ValueError(f"{location}: invalid numeric bound")


def evidence_file(root, relative):
    if "\\" in relative or ":" in relative or "\x00" in relative:
        raise ValueError("evidence paths must be portable run-relative paths")
    path = Path(relative)
    if path.is_absolute() or any(part in {".", ".."} for part in relative.split("/")):
        raise ValueError("evidence path escapes or aliases the run directory")
    target = (root / path).resolve(strict=True)
    if not target.is_relative_to(root.resolve()) or not target.is_file():
        raise ValueError("evidence must resolve to a file inside the run directory")
    return target


def artifact(root, relative):
    digest = hashlib.sha256()
    with evidence_file(root, relative).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return {"path": relative, "sha256": digest.hexdigest()}


def artifacts(meta):
    yield from meta["inputs"].values()
    yield from meta["execution"]["evidence"]
    yield from meta["qc"]["evidence"]
    yield from meta["resources"]["evidence"]


def validate(meta, root=None):
    schema = load_json(SCHEMA)
    check_schema(meta, schema, schema)
    execution = meta["execution"]
    status, code = execution["status"], execution["exit_code"]
    if status == "succeeded" and code != 0:
        raise ValueError("succeeded requires exit_code 0")
    if status in {"failed", "cancelled"} and (code is None or code == 0):
        raise ValueError("failed/cancelled requires a nonzero exit_code")
    if status in {"unknown", "running"} and code is not None:
        raise ValueError("unknown/running cannot assert a terminal exit_code")
    if status != "unknown" and not execution["evidence"]:
        raise ValueError("an execution status assertion requires evidence")
    if meta["qc"]["verdict"] != "NOT_ASSESSED" and not meta["qc"]["evidence"]:
        raise ValueError("a QC verdict requires evidence")
    if any(value is not None for group in ("predicted", "observed")
           for value in meta["resources"][group].values()) and not meta["resources"]["evidence"]:
        raise ValueError("resource estimates/measurements require evidence")
    for item in artifacts(meta):
        # Check portable paths even when file existence checks are not requested.
        path = item["path"]
        if "\\" in path or ":" in path or any(ord(c) < 32 for c in path):
            raise ValueError("evidence paths must be portable run-relative paths")
        if root is not None and artifact(root, path)["sha256"] != item["sha256"]:
            raise ValueError(f"evidence digest mismatch: {path}")


def init(args):
    root = args.run_dir.resolve(strict=True)
    if not root.is_dir():
        raise ValueError("run directory required")
    metric = {"wall_seconds": None, "work_peak_bytes": None, "memory_peak_bytes": None}
    result = {
        "schema_version": 1,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "run_id": root.name,
        "pipeline": {"name": args.pipeline, "revision": args.revision,
                     "engine_version": args.engine_version},
        "inputs": {name: artifact(root, getattr(args, name))
                   for name in ("samplesheet", "params", "command", "approval")},
        "execution": {"status": "unknown", "exit_code": None, "evidence": []},
        "qc": {"verdict": "NOT_ASSESSED", "evidence": []},
        "resources": {"predicted": metric.copy(), "observed": metric.copy(), "evidence": []},
    }
    validate(result, root)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    new = sub.add_parser("init", help="print a new unknown/NOT_ASSESSED snapshot to stdout")
    new.add_argument("run_dir", type=Path)
    new.add_argument("--pipeline", required=True)
    new.add_argument("--revision", required=True)
    new.add_argument("--engine-version", default=None)
    for name in ("samplesheet", "params", "command", "approval"):
        new.add_argument(f"--{name}", required=True, help="file path relative to run_dir")
    check = sub.add_parser("validate", help="read-only contract validation")
    check.add_argument("metadata", type=Path)
    check.add_argument("--check-files", action="store_true",
                       help="also verify evidence files and SHA256 under metadata's directory")
    args = parser.parse_args()
    try:
        if args.action == "init":
            print(json.dumps(init(args), indent=2, allow_nan=False))
        else:
            validate(load_json(args.metadata), args.metadata.resolve().parent if args.check_files else None)
            print(json.dumps({"valid": True, "checked_files": args.check_files}))
    except (ValueError, OSError, KeyError) as exc:
        print(f"run-meta: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
