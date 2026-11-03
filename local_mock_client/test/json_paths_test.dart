import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_client/src/json_paths.dart';
import 'package:local_mock_client/src/rule_drafts.dart';

import 'support/harness.dart';

void main() {
  group('pathAt', () {
    final text = const JsonEncoder.withIndent('  ').convert({
      'code': 0,
      'data': {
        'items': [
          {
            'name': 'a',
            'tags': ['x', 'y'],
          },
          {'name': 'b.c'},
        ],
      },
    });
    final nodes = indexJson(text)!;
    List<Object>? at(String needle, [int shift = 1]) =>
        pathAt(nodes, text.indexOf(needle) + shift);

    test('a property name selects its value', () {
      expect(at('"code"'), ['code']);
      expect(at('"items"'), ['data', 'items']);
    });

    test('a value selects the innermost field', () {
      expect(at('"a"'), ['data', 'items', 0, 'name']);
      expect(at('"y"'), ['data', 'items', 0, 'tags', 1]);
      expect(at('0,', 0), ['code']);
    });

    test('whitespace inside a container selects the container', () {
      final brace = text.lastIndexOf('{', text.indexOf('"b.c"'));
      expect(pathAt(nodes, brace + 1), ['data', 'items', 1]);
    });

    test('invalid JSON is not indexed', () {
      expect(indexJson('{"a": '), isNull);
    });
  });

  test('formatPath, wildcards and addressability', () {
    expect(formatPath(['data', 'items', 3, 'name']), 'data.items[3].name');
    expect(
      formatPath(['data', 'items', 3, 'name'], wildcards: {2}),
      'data.items[*].name',
    );
    expect(formatPath([0, 'name']), '[0].name');
    expect(isAddressable(['data', 'a.b']), isFalse);
    expect(isAddressable(['data', 'items', 1]), isTrue);
    expect(
      valueAt(
        {
          'a': [
            1,
            {'b': 2},
          ],
        },
        ['a', 1, 'b'],
      ),
      2,
    );
  });

  group('requestParams', () {
    test('query first, then flattened JSON body without duplicates', () {
      final params = requestParams(
        trafficEntry(
          1,
          '/x',
          query: 'id=1&id=2&page=3',
          request:
              '{"id": 9, "filter": {"city": "杭州"}, "items": [{"sku": "A"}]}',
        ),
      );
      expect(
        [for (final p in params) (p.key, p.value, p.fromQuery, p.topLevel)],
        [
          ('id', '1', true, true),
          ('page', '3', true, true),
          ('filter.city', '杭州', false, false),
          ('items[0].sku', 'A', false, false),
        ],
      );
    });

    test('URL-encoded form bodies', () {
      final params = requestParams(
        trafficEntry(1, '/x', method: 'POST', request: 'a=1&b=two'),
      );
      expect(params.map((p) => '${p.key}=${p.value}'), ['a=1', 'b=two']);
    });

    test('no parameters when there is neither query nor body', () {
      expect(requestParams(trafficEntry(1, '/x')), isEmpty);
    });
  });

  group('flattenParams', () {
    test('expands nested objects and arrays into field paths', () {
      expect(
        flattenParams({
          'modules': [1, 2],
          'filter': {
            'city': '杭州',
            'tags': [
              {'id': true},
            ],
          },
          'a.b': null,
        }),
        {
          'modules[0]': 1,
          'modules[1]': 2,
          'filter.city': '杭州',
          'filter.tags[0].id': true,
          'a.b': null,
        },
      );
    });

    test('flat and nested forms are equivalent', () {
      expect(
        flattenParams({
          'modules': [1, 2],
        }),
        flattenParams({'modules[0]': 1, 'modules[1]': 2}),
      );
    });

    test('rejects empty containers, bad names and duplicates', () {
      expect(() => flattenParams({'a': []}), throwsFormatException);
      expect(() => flattenParams({'a': {}}), throwsFormatException);
      expect(
        () => flattenParams({
          'a': {'b.c': 1},
        }),
        throwsFormatException,
      );
      expect(
        () => flattenParams({
          'a': [1],
          'a[0]': 2,
        }),
        throwsFormatException,
      );
    });
  });
}
