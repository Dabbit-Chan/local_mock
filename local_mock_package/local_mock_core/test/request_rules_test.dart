import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_core/local_mock_core.dart';
import 'package:local_mock_core/src/mock_registry.dart';

Map<String, dynamic> rule({
  Map<String, dynamic>? params,
  Map<String, dynamic>? patchBody,
}) => {
  'id': 'order',
  'method': 'GET',
  'path': '/api/order',
  if (params != null) 'params': params,
  if (patchBody != null) 'patchBody': patchBody,
};

void main() {
  final uri = Uri.parse('https://api.test/api/order');

  test('params match a subset and normalize primitive values', () {
    final parsed = MockRule.fromJson(
      rule(params: {'id': 123, 'preview': true}),
    );
    expect(parsed.params, {'id': '123', 'preview': 'true'});
    expect(
      parsed.matches('GET', uri.replace(query: 'id=123&preview=true&page=2')),
      isTrue,
    );
    for (final query in ['id=124&preview=true', 'id=123', 'preview=true', '']) {
      expect(parsed.matches('GET', uri.replace(query: query)), isFalse);
    }
    expect(MockRule.fromJson(parsed.toJson()).toJson(), parsed.toJson());
  });

  test('query supports percent encoding and repeated values', () {
    final parsed = MockRule.fromJson(rule(params: {'id': '测试 A'}));
    expect(
      parsed.matches(
        'GET',
        uri.replace(query: 'id=other&id=%E6%B5%8B%E8%AF%95+A'),
      ),
      isTrue,
    );
  });

  test('JSON objects, JSON strings and form strings support body params', () {
    final parsed = MockRule.fromJson(rule(params: {'id': 123}));
    for (final body in [
      {'id': 123, 'other': 'kept'},
      '{"id":123,"other":"kept"}',
      'id=123&other=kept',
    ]) {
      expect(parsed.matches('GET', uri, requestBody: body), isTrue);
    }
    for (final body in [
      null,
      '',
      'not json',
      'id=%ZZ',
      {'id': 124},
      {},
    ]) {
      expect(parsed.matches('GET', uri, requestBody: body), isFalse);
    }
  });

  test('query wins over the same key in the request body', () {
    final parsed = MockRule.fromJson(rule(params: {'id': '123'}));
    expect(
      parsed.matches(
        'GET',
        uri.replace(query: 'id=other'),
        requestBody: {'id': 123},
      ),
      isFalse,
    );
  });

  test('nested body paths, array indices and explicit null match safely', () {
    final parsed = MockRule.fromJson(
      rule(params: {'items[0].id': 123, 'filter.status': null}),
    );
    expect(
      parsed.matches(
        'GET',
        uri,
        requestBody: {
          'items': [
            {'id': 123},
          ],
          'filter': {'status': null},
        },
      ),
      isTrue,
    );
    expect(parsed.matches('GET', uri, requestBody: {}), isFalse);
    expect(
      MockRule.fromJson(
        rule(params: {'id': null}),
      ).matches('GET', uri, requestBody: {'other': null}),
      isFalse,
    );
  });

  test('first fully matching rule wins, not the first endpoint match', () {
    final registry = MockRegistry();
    registry.replace([
      rule(params: {'id': 123}),
      {...rule(), 'id': 'fallback'},
    ]);
    expect(registry.candidates('GET', uri), hasLength(2));
    expect(registry.match('GET', uri, requestBody: {'id': 123})?.id, 'order');
    expect(
      registry.match('GET', uri, requestBody: {'id': 456})?.id,
      'fallback',
    );
    expect(registry.match('POST', uri), isNull);
  });

  test('patch replaces only named fields and keeps each order state', () {
    final parsed = MockRule.fromJson(
      rule(
        patchBody: {
          'data.product': {'sku': 'same-product'},
        },
      ),
    );
    expect(parsed.isPatch, isTrue);
    for (final status in ['PAID', 'SHIPPED']) {
      final original = {
        'code': 0,
        'data': {
          'status': status,
          'product': {'sku': 'backend'},
        },
      };
      final patched = parsed.applyPatch(original) as Map<String, dynamic>;
      expect(patched, {
        'code': 0,
        'data': {
          'status': status,
          'product': {'sku': 'same-product'},
        },
      });
      patched['data']['product']['sku'] = 'mutated';
      expect(original['data'], {
        'status': status,
        'product': {'sku': 'backend'},
      });
      expect(parsed.patchBody['data.product'], {'sku': 'same-product'});
    }
    expect(MockRule.fromJson(parsed.toJson()).patchBody, parsed.patchBody);
  });

  test('patch supports arrays, new leaf fields and explicit null', () {
    final parsed = MockRule.fromJson(
      rule(patchBody: {'data.items[0].name': 'fixed', 'data.optional': null}),
    );
    expect(
      parsed.applyPatch({
        'data': {
          'items': [
            {'name': 'first', 'price': 99},
            {'name': 'second'},
          ],
        },
      }),
      {
        'data': {
          'items': [
            {'name': 'fixed', 'price': 99},
            {'name': 'second'},
          ],
          'optional': null,
        },
      },
    );
    final rootArray = MockRule.fromJson(rule(patchBody: {'[0].id': 10}));
    expect(
      rootArray.applyPatch([
        {'id': 1},
        {'id': 2},
      ]),
      [
        {'id': 10},
        {'id': 2},
      ],
    );
  });

  test('unusable patch is atomic and never mutates the original', () {
    final parsed = MockRule.fromJson(
      rule(patchBody: {'name': 'changed', 'missing.parent': 1}),
    );
    final original = {'name': 'backend'};
    expect(() => parsed.applyPatch(original), throwsFormatException);
    expect(original, {'name': 'backend'});
    for (final body in [null, 123, 'not json', []]) {
      expect(() => parsed.applyPatch(body), throwsFormatException);
    }
  });

  test(
    'invalid new fields are rejected and empty maps preserve legacy rules',
    () {
      for (final invalid in [
        {...rule(), 'params': []},
        {
          ...rule(),
          'params': {
            'id': [1],
          },
        },
        {
          ...rule(),
          'params': {
            'id': {'value': 1},
          },
        },
        {
          ...rule(),
          'params': {'': 'value'},
        },
        {...rule(), 'patchBody': []},
        rule(patchBody: {'': 1}),
        rule(patchBody: {'data..id': 1}),
        rule(patchBody: {'data.items[-1]': 1}),
      ]) {
        expect(() => MockRule.fromJson(invalid), throwsFormatException);
      }
      final parsed = MockRule.fromJson(rule(params: {}, patchBody: {}));
      expect(parsed.isPatch, isFalse);
      expect(parsed.toJson(), isNot(contains('params')));
      expect(parsed.toJson(), isNot(contains('patchBody')));
      expect(parsed.matches('GET', uri.replace(query: 'id=any')), isTrue);
    },
  );
}
