// Storage for the Analytics API token.
//
// The token is only persisted when the user ticks "Remember token". It is
// saved together with the API origin (scheme://host:port) it was entered
// for, and the store only hands it out for that same origin (see
// [TokenStore.readFor]), so a typo or a look-alike address never receives a
// remembered token.
//
// On desktop and mobile the entry is kept in the operating system's
// credential store (Windows Credential Manager / DPAPI, macOS Keychain,
// libsecret on Linux) through flutter_secure_storage.
//
// On the web, flutter_secure_storage encrypts the value with WebCrypto, but
// the key that encrypts it is kept in the same browser storage, so any
// script running on the site could read it. The token is therefore kept in
// the tab's sessionStorage only: it survives a reload of the tab and is
// discarded when the tab is closed. Tokens that older versions saved in
// localStorage are deleted.

import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable, kIsWeb, protected, visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A remembered token and the API origin it belongs to.
@immutable
class RememberedToken {
  const RememberedToken(this.token, this.origin);

  final String token;

  /// Normalised origin (see [TokenStore.originOf]), or null for an entry
  /// saved by an older version that did not record one.
  final String? origin;

  @override
  String toString() => 'RememberedToken(origin: $origin)'; // never the token
}

/// Where a remembered token is kept. Subclasses implement the raw
/// [loadEntry] / [saveEntry] / [delete]; callers use [readFor], [write],
/// [rememberedOrigin] and [mayBeSentTo], which enforce the origin binding.
abstract class TokenStore {
  /// The raw stored entry, or null. Use [readFor] instead: this does not
  /// check the origin.
  @protected
  Future<RememberedToken?> loadEntry();

  /// Replaces the stored entry.
  @protected
  Future<void> saveEntry(RememberedToken entry);

  /// Forgets the remembered token. Never throws.
  Future<void> delete();

  /// "scheme://host:port" of [baseUrl] with a lower-case host and the
  /// default port filled in, so `https://AVSM.example.edu/` and
  /// `https://avsm.example.edu:443/analytics` share one origin.
  static String originOf(Uri baseUrl) =>
      '${baseUrl.scheme.toLowerCase()}://${baseUrl.host.toLowerCase()}:${baseUrl.port}';

  /// Remembers [token] for [baseUrl]'s origin, replacing any other entry.
  Future<void> write(String token, {required Uri baseUrl}) =>
      saveEntry(RememberedToken(token, originOf(baseUrl)));

  /// The remembered token when it was saved for [baseUrl]'s origin, else
  /// null. A token is never returned for any other origin.
  ///
  /// [legacyBaseUrl] migrates an entry saved by an older version without an
  /// origin; see [_migrate].
  Future<String?> readFor(Uri baseUrl, {Uri? legacyBaseUrl}) async {
    final entry = await _migrate(legacyBaseUrl);
    if (entry == null || entry.origin != originOf(baseUrl)) return null;
    return entry.token;
  }

  /// The origin the remembered token belongs to, or null when nothing is
  /// remembered. Never returns the token itself.
  Future<String?> rememberedOrigin({Uri? legacyBaseUrl}) async =>
      (await _migrate(legacyBaseUrl))?.origin;

  /// False when [token] is the remembered token and [baseUrl] is a
  /// different origin from the one it was saved for: the app then refuses
  /// to send it. Any other token may be sent.
  Future<bool> mayBeSentTo(String token, Uri baseUrl, {Uri? legacyBaseUrl}) async {
    final entry = await _migrate(legacyBaseUrl);
    if (entry == null || entry.token != token) return true;
    return entry.origin == originOf(baseUrl);
  }

  /// Reads the entry, upgrading one saved without an origin.
  ///
  /// Older versions saved the token and the API address together (the
  /// address in the app settings, the token here) and only ever filled the
  /// token in for that saved address. Such a token is therefore bound to
  /// [legacyBaseUrl], the saved address, which keeps the behaviour users
  /// had. When there is no valid saved address the token's server is
  /// unknown, so it is deleted rather than guessed: the user enters it
  /// again.
  Future<RememberedToken?> _migrate(Uri? legacyBaseUrl) async {
    RememberedToken? entry;
    try {
      entry = await loadEntry();
    } catch (_) {
      return null;
    }
    if (entry == null || entry.origin != null) return entry;
    if (legacyBaseUrl == null || legacyBaseUrl.host.isEmpty) {
      await delete();
      return null;
    }
    final bound = RememberedToken(entry.token, originOf(legacyBaseUrl));
    try {
      await saveEntry(bound);
    } catch (_) {
      // Could not rewrite it: still use the binding for this session.
    }
    return bound;
  }

  /// Serialised form: JSON, so the origin and the token are written in one
  /// atomic operation. Tokens never contain `{` (see
  /// AnalyticsApiClient.validateToken), so a value that does not start with
  /// one is a bare token from an older version.
  @visibleForTesting
  static String encode(RememberedToken entry) =>
      jsonEncode({'v': 2, 'origin': entry.origin, 'token': entry.token});

  /// Parses [encode]'s output or a bare legacy token. Returns null for an
  /// unreadable value.
  @visibleForTesting
  static RememberedToken? decode(String? value) {
    if (value == null || value.isEmpty) return null;
    if (!value.startsWith('{')) return RememberedToken(value, null);
    try {
      final j = jsonDecode(value);
      if (j is! Map) return null;
      final token = j['token'], origin = j['origin'];
      if (token is! String || token.isEmpty || origin is! String || origin.isEmpty) return null;
      return RememberedToken(token, origin);
    } on FormatException {
      return null;
    }
  }
}

/// Default store backed by the platform credential store (sessionStorage
/// on the web).
class SecureTokenStore extends TokenStore {
  SecureTokenStore({FlutterSecureStorage? storage, FlutterSecureStorage? legacyWebStorage, bool isWeb = kIsWeb})
      : _storage = storage ??
            (isWeb
                ? const FlutterSecureStorage(webOptions: webOptions)
                : const FlutterSecureStorage(mOptions: macOsOptions)),
        _legacyWebStorage = isWeb ? (legacyWebStorage ?? const FlutterSecureStorage()) : null;

  static const String key = 'avsm_analytics_api_token';

  /// Web: keep the token in this tab's sessionStorage, never localStorage.
  static const WebOptions webOptions = WebOptions(useSessionStorage: true);

  /// macOS: use the login keychain rather than the data protection
  /// keychain. The data protection keychain needs the keychain-access-groups
  /// entitlement, which in turn needs a provisioning profile and would stop
  /// an unsigned or ad-hoc signed build from saving the token at all. Only
  /// read on macOS.
  static const MacOsOptions macOsOptions = MacOsOptions(usesDataProtectionKeychain: false);

  final FlutterSecureStorage _storage;

  /// Web only: the default (localStorage) store older versions used.
  final FlutterSecureStorage? _legacyWebStorage;
  bool _legacyPurged = false;

  /// Deletes a token an older version left in localStorage, and the
  /// encryption key stored next to it, once per run.
  Future<void> _purgeLegacyWebToken() async {
    final legacy = _legacyWebStorage;
    if (legacy == null || _legacyPurged) return;
    _legacyPurged = true;
    try {
      await legacy.deleteAll();
    } catch (_) {
      // Nothing stored or storage blocked: nothing to remove.
    }
  }

  @override
  Future<RememberedToken?> loadEntry() async {
    await _purgeLegacyWebToken();
    try {
      return TokenStore.decode(await _storage.read(key: key));
    } catch (_) {
      // A locked keychain or missing libsecret must not crash the app; the
      // user can still type the token.
      return null;
    }
  }

  @override
  Future<void> saveEntry(RememberedToken entry) async {
    await _purgeLegacyWebToken();
    await _storage.write(key: key, value: TokenStore.encode(entry));
  }

  @override
  Future<void> delete() async {
    await _purgeLegacyWebToken();
    try {
      await _storage.delete(key: key);
    } catch (_) {
      // Nothing stored or the store is unavailable: nothing to delete.
    }
  }
}

/// In-memory store for tests (and a safe fallback). [origin] null models a
/// token saved by an older version.
class MemoryTokenStore extends TokenStore {
  MemoryTokenStore([String? token, String? origin])
      : _entry = token == null ? null : RememberedToken(token, origin);

  RememberedToken? _entry;

  /// The raw entry, for tests.
  RememberedToken? get entry => _entry;

  @override
  Future<RememberedToken?> loadEntry() async => _entry;

  @override
  Future<void> saveEntry(RememberedToken entry) async => _entry = entry;

  @override
  Future<void> delete() async => _entry = null;
}
