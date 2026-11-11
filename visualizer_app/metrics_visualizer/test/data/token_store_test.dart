import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/data/token_store.dart';

const token = 'test-token-0123456789abcdefghijklmnopqrstuv';
final edu = Uri.parse('https://avsm.example.edu:8081');
final com = Uri.parse('https://avsm.example.com:8081');

/// Records which browser storage (session or local) each call used, based
/// on the instance's web options, like flutter_secure_storage_web does.
class FakeSecureStorage extends FlutterSecureStorage {
  FakeSecureStorage(this.stores, {super.webOptions});

  final Map<String, Map<String, String>> stores;
  Map<String, String> get _store =>
      stores.putIfAbsent(webOptions.useSessionStorage ? 'session' : 'local', () => {});

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      _store[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _store.remove(key);
    } else {
      _store[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      _store.remove(key);

  @override
  Future<void> deleteAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      _store.clear();
}

void main() {
  test('origins are normalised: case, default port and path prefix', () {
    expect(TokenStore.originOf(Uri.parse('https://AVSM.Example.edu/analytics')), 'https://avsm.example.edu:443');
    expect(TokenStore.originOf(Uri.parse('https://avsm.example.edu:443')), 'https://avsm.example.edu:443');
    expect(TokenStore.originOf(Uri.parse('http://avsm.example.edu')), 'http://avsm.example.edu:80');
    expect(TokenStore.originOf(edu), isNot(TokenStore.originOf(Uri.parse('http://avsm.example.edu:8081'))));
  });

  test('a token is only returned for the origin it was saved for', () async {
    final store = MemoryTokenStore();
    await store.write(token, baseUrl: edu);
    expect(store.entry!.origin, 'https://avsm.example.edu:8081');
    expect(await store.readFor(Uri.parse('https://avsm.example.edu:8081/prefix/')), token);
    expect(await store.readFor(com), isNull);
    expect(await store.readFor(Uri.parse('http://avsm.example.edu:8081')), isNull, reason: 'scheme differs');
    expect(await store.readFor(Uri.parse('https://avsm.example.edu')), isNull, reason: 'port differs');
    expect(await store.rememberedOrigin(), 'https://avsm.example.edu:8081');
    expect(await store.delete().then((_) => store.readFor(edu)), isNull);
  });

  test('the remembered token may not be sent to another origin; other tokens may', () async {
    final store = MemoryTokenStore();
    await store.write(token, baseUrl: edu);
    expect(await store.mayBeSentTo(token, edu), isTrue);
    expect(await store.mayBeSentTo(token, com), isFalse);
    expect(await store.mayBeSentTo('another-token-0123456789abcdefghijklmnop', com), isTrue);
  });

  test('a legacy token without an origin is bound to the saved address', () async {
    final store = MemoryTokenStore(token);
    expect(await store.readFor(com, legacyBaseUrl: edu), isNull);
    expect(store.entry!.origin, 'https://avsm.example.edu:8081', reason: 'rewritten with its origin');
    expect(await store.readFor(edu), token, reason: 'bound for good, no legacy address needed');
    expect(await store.readFor(com, legacyBaseUrl: com), isNull, reason: 'cannot be re-bound later');
  });

  test('a legacy token with no saved address is deleted, not guessed', () async {
    final store = MemoryTokenStore(token);
    expect(await store.readFor(edu), isNull);
    expect(store.entry, isNull);
    final again = MemoryTokenStore(token);
    expect(await again.mayBeSentTo(token, edu), isTrue, reason: 'nothing is remembered any more');
    expect(again.entry, isNull);
  });

  test('entries are encoded with their origin; bare values are legacy tokens', () {
    final entry = TokenStore.decode(TokenStore.encode(const RememberedToken(token, 'https://a.example:443')))!;
    expect(entry.token, token);
    expect(entry.origin, 'https://a.example:443');
    expect(TokenStore.decode(token)!.origin, isNull);
    expect(TokenStore.decode(null), isNull);
    expect(TokenStore.decode('{"token": "x"}'), isNull, reason: 'no origin: unusable');
    expect(TokenStore.decode('{broken'), isNull);
    expect(const RememberedToken(token, 'o').toString(), isNot(contains(token)));
  });

  test('desktop: one entry with the origin in the credential store', () async {
    final stores = <String, Map<String, String>>{};
    final store = SecureTokenStore(storage: FakeSecureStorage(stores), isWeb: false);
    await store.write(token, baseUrl: edu);
    expect(stores['local']![SecureTokenStore.key], contains('https://avsm.example.edu:8081'));
    expect(await store.readFor(edu), token);
    await store.delete();
    expect(stores['local'], isEmpty);
  });

  test('macOS: the login keychain is used, so no keychain-access-groups entitlement is needed', () {
    expect(SecureTokenStore.macOsOptions.usesDataProtectionKeychain, isFalse);
    expect(SecureTokenStore.macOsOptions.toMap()['usesDataProtectionKeychain'], 'false');
  });

  test('web: the token lives in session storage and old localStorage copies are removed', () async {
    expect(SecureTokenStore.webOptions.useSessionStorage, isTrue);
    final stores = <String, Map<String, String>>{
      'local': {SecureTokenStore.key: token, 'FlutterSecureStorage': 'old-wrapping-key'},
    };
    final store = SecureTokenStore(
      storage: FakeSecureStorage(stores, webOptions: SecureTokenStore.webOptions),
      legacyWebStorage: FakeSecureStorage(stores),
      isWeb: true,
    );
    expect(await store.readFor(edu, legacyBaseUrl: edu), isNull, reason: 'a localStorage token is not used');
    expect(stores['local'], isEmpty);
    await store.write(token, baseUrl: edu);
    expect(stores['session']![SecureTokenStore.key], isNotNull);
    expect(stores['local'], isEmpty);
    expect(await store.readFor(edu), token);
  });
}
