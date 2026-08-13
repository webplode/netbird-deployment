#!/usr/bin/env python3
"""Edit one value in terraform.tfvars in place, with strict verification.

Usage:
    set-tfvar.py <tfvars-file> <key> <raw-hcl-value>

Supported keys:
    - top-level scalars:            eip_cutover_confirmation '"REASSOCIATE..."'
    - one level inside an object:   bootstrap_enabled.management true
                                    eip_rollback_instance_ids.peer_1 '"i-0abc..."'

The value is inserted verbatim (quote strings yourself). The script fails if
the key is not found exactly once, and re-reads the file afterwards to verify
the assignment took effect.
"""
import re
import sys


def fail(msg: str) -> None:
    print(f"FATAL set-tfvar: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    if len(sys.argv) != 4:
        fail(f"usage: {sys.argv[0]} <tfvars-file> <key> <raw-hcl-value>")
    path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
    with open(path, encoding="utf-8") as handle:
        text = handle.read()

    if "." in key:
        block, attr = key.split(".", 1)
        if "." in attr:
            fail("only one level of nesting is supported")
        block_re = re.compile(
            rf"(^{re.escape(block)}\s*=\s*\{{)(.*?)(^\}})",
            re.MULTILINE | re.DOTALL,
        )
        match = block_re.search(text)
        if not match:
            fail(f"block '{block}' not found in {path}")
        body = match.group(2)
        attr_re = re.compile(rf"(^\s*{re.escape(attr)}\s*=\s*)(.*?)(\s*(#.*)?$)", re.MULTILINE)
        hits = attr_re.findall(body)
        if len(hits) != 1:
            fail(f"attribute '{attr}' found {len(hits)} times in block '{block}'")
        new_body = attr_re.sub(lambda m: m.group(1) + value + m.group(3), body, count=1)
        text = text[: match.start(2)] + new_body + text[match.end(2):]
        verify_re = re.compile(
            rf"^{re.escape(block)}\s*=\s*\{{[^{{}}]*^\s*{re.escape(attr)}\s*=\s*{re.escape(value)}\s*(#.*)?$",
            re.MULTILINE | re.DOTALL,
        )
    else:
        scalar_re = re.compile(rf"(^{re.escape(key)}\s*=\s*)(.*?)(\s*(#.*)?$)", re.MULTILINE)
        hits = scalar_re.findall(text)
        if len(hits) != 1:
            fail(f"key '{key}' found {len(hits)} times in {path}")
        text = scalar_re.sub(lambda m: m.group(1) + value + m.group(3), text, count=1)
        verify_re = re.compile(rf"^{re.escape(key)}\s*=\s*{re.escape(value)}\s*(#.*)?$", re.MULTILINE)

    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    with open(path, encoding="utf-8") as handle:
        if not verify_re.search(handle.read()):
            fail(f"post-write verification failed for {key} = {value}")
    print(f"set-tfvar OK: {key} = {value}")


if __name__ == "__main__":
    main()
