import 'dart:convert';

/// A JSON value inside a text, with its location and path from the root.
class JsonNode {
  JsonNode(this.path, this.start, this.end, {this.keyStart, this.keyEnd});

  /// Object keys (String) and array indexes (int) from the root.
  final List<Object> path;

  /// Span of the value in the source text.
  final int start;
  final int end;

  /// Span of the property name when the value belongs to an object.
  final int? keyStart;
  final int? keyEnd;

  bool contains(int offset) =>
      (offset >= start && offset < end) ||
      (keyStart != null && offset >= keyStart! && offset < keyEnd!);
}

/// Parses [text] and returns every value with its span, or null when the
/// text is not valid JSON.
List<JsonNode>? indexJson(String text) {
  try {
    jsonDecode(text);
  } on FormatException {
    return null;
  }
  final nodes = <JsonNode>[];
  _Scanner(text, nodes).root();
  return nodes;
}

/// Path of the innermost value at [offset] (a property name counts as its
/// value), or null when [offset] is outside any value.
List<Object>? pathAt(List<JsonNode> nodes, int offset) {
  JsonNode? best;
  for (final node in nodes) {
    if (node.contains(offset) &&
        (best == null || node.path.length > best.path.length)) {
      best = node;
    }
  }
  return best?.path;
}

/// The value at [path] inside decoded JSON [root].
Object? valueAt(Object? root, List<Object> path) {
  var current = root;
  for (final segment in path) {
    current = switch ((current, segment)) {
      (Map m, String key) => m[key],
      (List l, int i) when i < l.length => l[i],
      _ => null,
    };
  }
  return current;
}

/// Whether [path] can be written as a local_mock field path: names with `.`,
/// `[` or `]` cannot be addressed.
bool isAddressable(List<Object> path) => path.every(
  (s) =>
      s is int ||
      (s is String && s.isNotEmpty && !s.contains(RegExp(r'[.\[\]]'))),
);

/// `data.items[0].name`; [wildcards] replaces the given array positions
/// (indexes into [path]) with `[*]`.
String formatPath(List<Object> path, {Set<int> wildcards = const {}}) {
  final out = StringBuffer();
  for (final (i, segment) in path.indexed) {
    if (segment is int) {
      out.write(wildcards.contains(i) ? '[*]' : '[$segment]');
    } else {
      if (out.isNotEmpty) out.write('.');
      out.write(segment);
    }
  }
  return out.toString();
}

/// Leaf values (strings, numbers, booleans, null) of [root] with their
/// paths, depth-first, at most [limit].
List<(List<Object>, Object?)> leaves(Object? root, {int limit = 200}) {
  final result = <(List<Object>, Object?)>[];
  void walk(Object? value, List<Object> path) {
    if (result.length >= limit) return;
    if (value is Map) {
      for (final entry in value.entries) {
        walk(entry.value, [...path, '${entry.key}']);
      }
    } else if (value is List) {
      for (final (i, item) in value.indexed) {
        walk(item, [...path, i]);
      }
    } else if (path.isNotEmpty) {
      result.add((path, value));
    }
  }

  walk(root, const []);
  return result;
}

class _Scanner {
  _Scanner(this.text, this.nodes);

  final String text;
  final List<JsonNode> nodes;
  int i = 0;

  void root() {
    _ws();
    _value(const [], null, null);
  }

  void _ws() {
    while (i < text.length && ' \t\r\n'.contains(text[i])) {
      i++;
    }
  }

  String _string() {
    final start = i;
    i++; // opening quote
    while (text[i] != '"') {
      i += text[i] == r'\' ? 2 : 1;
    }
    i++;
    return jsonDecode(text.substring(start, i)) as String;
  }

  void _value(List<Object> path, int? keyStart, int? keyEnd) {
    final start = i;
    final c = text[i];
    if (c == '{') {
      i++;
      _ws();
      while (text[i] != '}') {
        final ks = i;
        final key = _string();
        final ke = i;
        _ws();
        i++; // colon
        _ws();
        _value([...path, key], ks, ke);
        _ws();
        if (text[i] == ',') {
          i++;
          _ws();
        }
      }
      i++;
    } else if (c == '[') {
      i++;
      _ws();
      var index = 0;
      while (text[i] != ']') {
        _value([...path, index++], null, null);
        _ws();
        if (text[i] == ',') {
          i++;
          _ws();
        }
      }
      i++;
    } else if (c == '"') {
      _string();
    } else {
      while (i < text.length && !',}] \t\r\n'.contains(text[i])) {
        i++;
      }
    }
    nodes.add(JsonNode(path, start, i, keyStart: keyStart, keyEnd: keyEnd));
  }
}

/// Flattens nested objects and arrays in a params condition into
/// `path: value` pairs, e.g. `{"modules": [1, 2]}` becomes
/// `{"modules[0]": 1, "modules[1]": 2}`. Primitive top-level entries keep
/// their key as written, so `{"filter.id": 1}` stays as is.
///
/// Throws [FormatException] with a user-facing message when a nested value
/// cannot be expressed as a field path.
Map<String, Object?> flattenParams(Map<String, dynamic> params) {
  final result = <String, Object?>{};
  void walk(Object? value, String key) {
    if (value is Map) {
      if (value.isEmpty) throw FormatException('"$key" 是空对象，无法匹配');
      for (final entry in value.entries) {
        final name = '${entry.key}';
        if (!isAddressable([name])) {
          throw FormatException('"$key" 下的字段名 "$name" 不能含 . [ ] 或为空');
        }
        walk(entry.value, '$key.$name');
      }
    } else if (value is List) {
      if (value.isEmpty) throw FormatException('"$key" 是空数组，无法匹配');
      for (final (i, item) in value.indexed) {
        walk(item, '$key[$i]');
      }
    } else {
      if (result.containsKey(key)) throw FormatException('参数 "$key" 重复');
      result[key] = value;
    }
  }

  for (final entry in params.entries) {
    walk(entry.value, entry.key);
  }
  return result;
}
