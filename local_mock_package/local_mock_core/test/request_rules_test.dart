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

  test(
    'wildcard patches every album name and keeps unrelated response fields',
    () {
      final parsed = MockRule.fromJson(
        rule(patchBody: {'data.sitePhotoAlbumList[*].name': '很长很长的相册名'}),
      );
      final original = {
        'code': '0',
        'data': {
          'title': 'original',
          'sitePhotoAlbumList': [
            {'id': 2334, 'name': '全部'},
            {'id': 2335, 'name': '天然虾青素'},
          ],
        },
      };
      expect(parsed.applyPatch(original), {
        'code': '0',
        'data': {
          'title': 'original',
          'sitePhotoAlbumList': [
            {'id': 2334, 'name': '很长很长的相册名'},
            {'id': 2335, 'name': '很长很长的相册名'},
          ],
        },
      });
      expect((original['data'] as Map)['sitePhotoAlbumList'], [
        {'id': 2334, 'name': '全部'},
        {'id': 2335, 'name': '天然虾青素'},
      ]);
      expect(MockRule.fromJson(parsed.toJson()).patchBody, parsed.patchBody);
    },
  );

  test('wildcards support nested arrays and a root array', () {
    final parsed = MockRule.fromJson(rule(patchBody: {'[*][*].name': 'fixed'}));
    expect(
      parsed.applyPatch([
        [
          {'name': 'first'},
          {'name': 'second'},
        ],
        [],
        [
          {'name': 'third'},
        ],
      ]),
      [
        [
          {'name': 'fixed'},
          {'name': 'fixed'},
        ],
        [],
        [
          {'name': 'fixed'},
        ],
      ],
    );
    final root = MockRule.fromJson(rule(patchBody: {'[*].name': 'fixed'}));
    expect(
      root.applyPatch([
        {'id': 1},
        {'id': 2},
      ]),
      [
        {'id': 1, 'name': 'fixed'},
        {'id': 2, 'name': 'fixed'},
      ],
    );
  });

  test('wildcard values are copied independently for every target', () {
    for (final value in [
      null,
      123,
      {
        'nested': [1, 2],
      },
    ]) {
      final parsed = MockRule.fromJson(rule(patchBody: {'[*]': value}));
      final original = ['first', 'second'];
      final patched = parsed.applyPatch(original) as List;
      expect(patched, [value, value]);
      expect(original, ['first', 'second']);
      if (value is Map) {
        patched.first['nested'][0] = 99;
        expect(patched.last, {
          'nested': [1, 2],
        });
        expect(parsed.patchBody['[*]'], {
          'nested': [1, 2],
        });
        expect(parsed.applyPatch(original), [value, value]);
      }
    }
  });

  test('empty wildcard targets do not block other patches', () {
    final parsed = MockRule.fromJson(
      rule(patchBody: {'items[*].name': 'fixed', 'title': 'changed'}),
    );
    expect(parsed.applyPatch({'items': [], 'title': 'original'}), {
      'items': [],
      'title': 'changed',
    });
    expect(MockRule.fromJson(rule(patchBody: {'[*]': 1})).applyPatch([]), []);
  });

  test(
    'out-of-range indices skip only their path regardless of patch order',
    () {
      for (final patch in [
        {
          'data.items[9].missing.parent': 'ignored',
          'data.items[0].name': 'fixed',
          'data.items[1]': null,
          'data.items.99.name': 'ignored',
          'data.items[999999999999999999999999999999]': 'ignored',
          'data.title': 'changed',
        },
        {
          'data.title': 'changed',
          'data.items[0].name': 'fixed',
          'data.items[9].name': 'ignored',
        },
      ]) {
        final parsed = MockRule.fromJson(rule(patchBody: patch));
        final original = {
          'data': {
            'items': [
              {'name': 'original'},
            ],
            'title': 'original',
          },
        };
        expect(parsed.applyPatch(original), {
          'data': {
            'items': [
              {'name': 'fixed'},
            ],
            'title': 'changed',
          },
        });
        expect(original['data']!['title'], 'original');
      }
      final skipped = MockRule.fromJson(
        rule(patchBody: {'[0].name': 'ignored'}),
      );
      expect(skipped.applyPatch([]), []);
    },
  );

  test(
    'out-of-range indices in wildcard branches leave other targets intact',
    () {
      final parsed = MockRule.fromJson(
        rule(
          patchBody: {
            'groups[*].items[1].name': 'fixed',
            'groups[8].items[*].name': 'ignored',
            'title': 'changed',
          },
        ),
      );
      expect(
        parsed.applyPatch({
          'title': 'original',
          'groups': [
            {
              'items': [
                {'name': 'first'},
                {'name': 'second'},
              ],
            },
            {'items': []},
            {
              'items': [
                {'name': 'only'},
              ],
            },
            {
              'items': [
                {'name': 'third'},
                {'name': 'fourth'},
              ],
            },
          ],
        }),
        {
          'title': 'changed',
          'groups': [
            {
              'items': [
                {'name': 'first'},
                {'name': 'fixed'},
              ],
            },
            {'items': []},
            {
              'items': [
                {'name': 'only'},
              ],
            },
            {
              'items': [
                {'name': 'third'},
                {'name': 'fixed'},
              ],
            },
          ],
        },
      );
    },
  );

  test('wildcards and indexed overrides apply in declaration order', () {
    final parsed = MockRule.fromJson(
      rule(
        patchBody: {
          'items[*].name': 'all',
          'items[0].name': 'first only',
          'items[9].name': 'ignored',
        },
      ),
    );
    expect(
      parsed.applyPatch({
        'items': [
          {'name': 'first'},
          {'name': 'second'},
        ],
      }),
      {
        'items': [
          {'name': 'first only'},
          {'name': 'all'},
        ],
      },
    );
    final literal = MockRule.fromJson(
      rule(patchBody: {'data.*': 'literal key'}),
    );
    expect(
      literal.applyPatch({
        'data': {'*': 'original'},
      }),
      {
        'data': {'*': 'literal key'},
      },
    );
  });

  test(
    'wildcards require an array and do not add wildcard parameter matching',
    () {
      final parsed = MockRule.fromJson(
        rule(patchBody: {'items[*].name': 'fixed'}),
      );
      for (final items in [
        null,
        1,
        'text',
        {'name': 'not an array'},
      ]) {
        expect(
          () => parsed.applyPatch({'items': items}),
          throwsFormatException,
        );
      }
      final params = MockRule.fromJson(rule(params: {'items[*].id': 123}));
      expect(
        params.matches(
          'GET',
          uri,
          requestBody: {
            'items': [
              {'id': 123},
            ],
          },
        ),
        isFalse,
      );
    },
  );

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
        rule(patchBody: {'data.items[**].name': 1}),
        rule(patchBody: {'data.items[*]name': 1}),
        rule(patchBody: {'data.items[*].': 1}),
        rule(patchBody: {'data.items[ * ].name': 1}),
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
