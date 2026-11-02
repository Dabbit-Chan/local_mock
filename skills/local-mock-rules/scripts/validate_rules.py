#!/usr/bin/env python3
"""Validate local_mock rules with the same constraints as MockRule.parseList.

Accepts a single rule object, comma-separated rule objects, or a JSON array
(including recording groups from files exported by the console).

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


def _field_path(path):
    if not re.fullmatch(
        r"(?:[^.\[\]]+|\[(?:\*|0|[1-9][0-9]*)\])(?:\[(?:\*|0|[1-9][0-9]*)\]|\.[^.\[\]]+)*",
        path,
    ):
        raise ValueError(f"invalid field path: {path}")
    normalized = re.sub(r"\[(\*|0|[1-9][0-9]*)\]", r".\1", path).lstrip(".")
    if any(not segment.strip() for segment in normalized.split(".")):
        raise ValueError(f"invalid field path: {path}")


def _recorded_request(value):
    if (
        not isinstance(value, dict)
        or not isinstance(value.get("query"), dict)
        or (value.get("body") is not None and not isinstance(value["body"], str))
    ):
        raise ValueError("recordedRequest must contain query and optional body text")
    for item in value["query"].values():
        if not isinstance(item, list) or any(not isinstance(v, str) for v in item):
            raise ValueError("recorded query values must be string arrays")


def _validate_list(rules, children=False):
    ids = set()
    for index, rule in enumerate(rules):
        label = f"rules[{index}]" if children else f"rule[{index}]"
        try:
            if children and isinstance(rule, dict) and rule.get("type") is not None:
                raise ValueError("recording Mock can only contain response rules")
            rule_id = validate_rule(rule)
        except ValueError as error:
            raise ValueError(f"{label}: {error}") from None
        if rule_id in ids:
            raise ValueError(f"{label}: duplicate rule ID: {rule_id}")
        ids.add(rule_id)


def _validate_group(rule):
    """A recording group exported by the console (type: recording)."""
    rule_id = _text(rule, "id")
    _text(rule, "name")
    _text(rule, "recordingId")
    if not isinstance(rule.get("enabled", True), bool):
        raise ValueError("enabled must be a boolean")
    match_params = rule.get("matchParams", False)
    children = rule.get("rules")
    if not isinstance(match_params, bool) or not isinstance(children, list) or not children:
        raise ValueError("recording Mock needs rules and a boolean matchParams")
    _validate_list(children, children=True)
    return rule_id


def validate_rule(rule):
    if not isinstance(rule, dict):
        raise ValueError("each rule must be an object")
    if rule.get("type") == "recording":
        return _validate_group(rule)
    if rule.get("type") is not None:
        raise ValueError("unknown rule type")
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
    params = rule.get("params")
    if params is None:
        params = {}
    if not isinstance(params, dict) or any(
        not key.strip()
        or (value is not None and not isinstance(value, (str, int, float, bool)))
        for key, value in params.items()
    ):
        raise ValueError(
            "params must be an object with non-empty keys and primitive values"
        )
    patch_body = rule.get("patchBody")
    if patch_body is None:
        patch_body = {}
    if not isinstance(patch_body, dict):
        raise ValueError("patchBody must be an object")
    for field_path in patch_body:
        _field_path(field_path)
    _number(rule, "statusCode", 100, 599)
    _number(rule, "delayMs", 0, 60000)
    if rule.get("responseText") is not None and not isinstance(
        rule["responseText"], str
    ):
        raise ValueError("responseText must be a string")
    if rule.get("recordedRequest") is not None:
        _recorded_request(rule["recordedRequest"])
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
    _validate_list(data)
    return len(data)


def main():
    try:
        if len(sys.argv) > 1:
            with open(sys.argv[1], encoding="utf-8-sig") as file:
                text = file.read()
        else:
            text = sys.stdin.read().lstrip("\ufeff")
        count = validate(parse(text))
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"INVALID: {error}", file=sys.stderr)
        return 1
    print(f"OK: {count} rule(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
