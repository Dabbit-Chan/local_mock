#!/usr/bin/env python3
"""Validate local_mock rules with the same constraints as MockRule.parseList.

Accepts a single rule object, comma-separated rule objects, or a JSON array.

Usage:
  python3 validate_rules.py rules.json
  python3 validate_rules.py < rules.json
"""

import json
import re
import sys


def _is_int(value):
    # bool is a subclass of int in Python; Dart's `is int` rejects it.
    return isinstance(value, int) and not isinstance(value, bool)


def _text(rule, key):
    value = rule.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{key} must be a non-empty string")
    return value


def _number(rule, key, low, high):
    value = rule.get(key)
    if value is None:
        return
    if not _is_int(value) or not low <= value <= high:
        raise ValueError(f"{key} must be an integer in {low}..{high}")


def validate_rule(rule):
    if not isinstance(rule, dict):
        raise ValueError("each rule must be an object")
    rule_id = _text(rule, "id")
    method = _text(rule, "method")
    if not re.fullmatch(r"[A-Za-z]+", method):
        raise ValueError("method must contain only ASCII letters")
    path = _text(rule, "path")
    if not path.startswith("/") or "?" in path or "#" in path:
        raise ValueError("path must start with /, without query or fragment")
    enabled = rule.get("enabled", True)
    if not isinstance(enabled, bool):
        raise ValueError("enabled must be a boolean")
    host = rule.get("host")
    if host is not None and (not isinstance(host, str) or not host.strip()):
        raise ValueError("host must be a non-empty string or null")
    headers = rule.get("headers", {})
    if headers is None:
        headers = {}
    if not isinstance(headers, dict) or any(
        not isinstance(v, str) for v in headers.values()
    ):
        raise ValueError("headers must be an object with string values")
    _number(rule, "statusCode", 100, 599)
    _number(rule, "delayMs", 0, 60000)
    return rule_id


def parse(text):
    """Parses a rule object, comma-separated objects, or an array into a list."""
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        # Comma-separated objects are valid once wrapped in brackets.
        data = json.loads(f"[{text}]")
    return [data] if isinstance(data, dict) else data


def validate(data):
    if not isinstance(data, list):
        raise ValueError("rules must be JSON objects or an array of objects")
    ids = set()
    for index, rule in enumerate(data):
        try:
            rule_id = validate_rule(rule)
        except ValueError as error:
            raise ValueError(f"rule[{index}]: {error}") from None
        if rule_id in ids:
            raise ValueError(f"rule[{index}]: duplicate rule ID: {rule_id}")
        ids.add(rule_id)
    return len(data)


def main():
    try:
        if len(sys.argv) > 1:
            with open(sys.argv[1], encoding="utf-8") as file:
                text = file.read()
        else:
            text = sys.stdin.read()
        count = validate(parse(text))
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"INVALID: {error}", file=sys.stderr)
        return 1
    print(f"OK: {count} rule(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
