import 'dart:async';

import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/observability/sentry_service.dart';
import '../../../core/widgets/user_avatar_image.dart';
import '../../../features/auth/presentation/auth_providers.dart';
import '../api/user_api.dart';
import '../server_providers.dart';
import 'auth_backend.dart';
import 'auth_token_store.dart';
import 'user_profile_store.dart';

final userProfileProvider =
    NotifierProvider<UserProfileController, UserProfile?>(
        UserProfileController.new);

final avatarImageRevisionProvider = StateProvider<int>((ref) => 0);

/// [Image.network] cache key — include profile id / revision so account
/// switches never reuse the previous user's bitmap when URLs collide.
String avatarImageCacheKey({
  required int profileId,
  required String avatarUrl,
  int revision = 0,
}) =>
    '$profileId|${avatarUrl.trim()}|$revision';

String avatarImageUrl({
  required String avatarUrl,
  required int revision,
}) {
  final raw = avatarUrl.trim();
  if (raw.isEmpty || revision <= 0) return raw;
  final uri = Uri.tryParse(raw);
  if (uri == null) return raw;
  return uri.replace(
    queryParameters: {
      ...uri.queryParameters,
      '_avatar_v': revision.toString(),
    },
  ).toString();
}

bool _isSameUserId(UserProfile? current, UserProfile next) {
  if (current == null) return false;
  if (current.id > 0 && next.id > 0) return current.id == next.id;
  return false;
}

bool _userIdsConflict(UserProfile? a, UserProfile? b) {
  final aid = a?.id ?? 0;
  final bid = b?.id ?? 0;
  if (aid <= 0 || bid <= 0) return false;
  return aid != bid;
}

bool _sameProfile(UserProfile? a, UserProfile? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  return a.id == b.id &&
      (a.name ?? '').trim() == (b.name ?? '').trim() &&
      (a.email ?? '').trim().toLowerCase() ==
          (b.email ?? '').trim().toLowerCase() &&
      (a.avatarUrl ?? '').trim() == (b.avatarUrl ?? '').trim() &&
      a.emailVerified == b.emailVerified &&
      (a.provider ?? '') == (b.provider ?? '') &&
      (a.role ?? '') == (b.role ?? '') &&
      a.hasPwd == b.hasPwd;
}

String _avatarResourceKey(String? value) {
  final raw = (value ?? '').trim();
  final uri = Uri.tryParse(raw);
  if (uri == null) return raw;
  final query = Map<String, String>.from(uri.queryParameters)
    ..remove('timestamp')
    ..remove('_avatar_v');
  return uri.replace(queryParameters: query).toString();
}

String? _preferStableAvatarUrl(String? fetched, String? current) {
  final next = (fetched ?? '').trim();
  final previous = (current ?? '').trim();
  if (next.isEmpty) return previous.isEmpty ? null : previous;
  if (previous.isNotEmpty &&
      _avatarResourceKey(next) == _avatarResourceKey(previous)) {
    return previous;
  }
  return next;
}

class UserProfileController extends Notifier<UserProfile?> {
  /// Bumped on login / logout / account switch so in-flight [refresh] results
  /// for a previous account are never applied on top of the new one.
  int _generation = 0;

  /// Last SenseCraft **org** user_id seen from `getUserOrgInfo`.
  ///
  /// The *business* login id (our DB key) can stay stable across an account
  /// delete + re-register under the same third-party identity — notably Apple,
  /// whose `sub` is permanent — while the **org** user_id and avatar are reset
  /// server-side. Tracking the org id lets us detect that reset and drop the
  /// deleted account's avatar instead of resurrecting it via the "keep previous
  /// avatar" fallback. In-memory only; seeded from the cached avatar URL after
  /// a cold start (see [_orgIdFromAvatarUrl]).
  int _lastOrgUserId = 0;

  @override
  UserProfile? build() => UserProfileStore.cached;

  void _evictAvatarCache(String? url) {
    final u = (url ?? '').trim();
    if (u.isEmpty) return;
    try {
      PaintingBinding.instance.imageCache.evict(NetworkImage(u));
    } catch (_) {
      // ignore
    }
  }

  void _bumpAvatarRevision() {
    ref.read(avatarImageRevisionProvider.notifier).state++;
  }

  bool _avatarChanged(String? a, String? b) =>
      (a ?? '').trim() != (b ?? '').trim();

  void markAvatarImageChanged() {
    _bumpAvatarRevision();
    _evictAvatarCache(state?.avatarUrl);
  }

  void setFromLogin(UserProfile user) {
    _setFromLoginLocal(user);
    unawaited(refresh().catchError((_) => state));
  }

  Future<UserProfile?> setFromLoginAndRefresh(UserProfile user) async {
    _setFromLoginLocal(user);
    try {
      return await refresh();
    } catch (_) {
      return state;
    }
  }

  void _setFromLoginLocal(UserProfile user) {
    final prev = state;
    // The login response may omit a numeric id (id<=0). Writing that as-is makes
    // [accountDbKeyProvider] flap to null and back when the real id arrives from
    // a profile refresh, which closes/reopens the SQLite shard mid-query and
    // surfaces as a stuck "database_closed". Preserve the last known good id so
    // the account key stays stable across login → refresh — but never carry an
    // old id (or cached avatar) across a different account.
    final switchingAccount = !_isSameUserId(prev, user);
    if (switchingAccount) {
      _generation++;
      // Drop in-flight UserProfileStore.save from the previous account so a
      // late write cannot poison [UserProfileStore.cached] after logout/login.
      UserProfileStore.bumpEpoch();
    }
    var next = (!switchingAccount &&
            user.id <= 0 &&
            (prev?.id ?? 0) > 0)
        ? _withId(user, prev!.id)
        : user;
    // Login payloads may omit avatar_url. Never keep the previous account's
    // avatar across a switch, but do use the new login payload's avatar when
    // the business exchange already returned one.
    if (switchingAccount) {
      next = UserProfile(
        id: next.id,
        name: next.name,
        email: next.email,
        emailVerified: next.emailVerified,
        avatarUrl: _trimToNull(next.avatarUrl),
        provider: next.provider,
        role: next.role,
        hasPwd: next.hasPwd,
      );
    }
    final prevAvatar = prev?.avatarUrl;
    state = next;
    unawaited(UserProfileStore.save(next));
    _evictAvatarCache(prevAvatar);
    _evictAvatarCache(next.avatarUrl);
    if (switchingAccount || _avatarChanged(prevAvatar, next.avatarUrl)) {
      AvatarDecodedCache.clear();
      _bumpAvatarRevision();
      try {
        PaintingBinding.instance.imageCache.clear();
      } catch (_) {
        // ignore
      }
    }
    unawaited(
      SentryService.setUser(userId: next.id, email: next.email),
    );
  }

  UserProfile _withId(UserProfile u, int id) => UserProfile(
        id: id,
        name: u.name,
        email: u.email,
        emailVerified: u.emailVerified,
        avatarUrl: u.avatarUrl,
        provider: u.provider,
        role: u.role,
        hasPwd: u.hasPwd,
      );

  void updateEmailLocal(String email) {
    final next = email.trim();
    final cur = state;
    if (cur == null) return;
    final updated = UserProfile(
      id: cur.id,
      name: cur.name,
      email: next,
      emailVerified: cur.emailVerified,
      avatarUrl: cur.avatarUrl,
      provider: cur.provider,
      role: cur.role,
      hasPwd: cur.hasPwd,
    );
    state = updated;
    unawaited(UserProfileStore.save(updated));
  }

  void updateNameLocal(String name) {
    final next = name.trim();
    final cur = state;
    if (cur == null) return;
    final updated = UserProfile(
      id: cur.id,
      name: next,
      email: cur.email,
      emailVerified: cur.emailVerified,
      avatarUrl: cur.avatarUrl,
      provider: cur.provider,
      role: cur.role,
      hasPwd: cur.hasPwd,
    );
    state = updated;
    unawaited(UserProfileStore.save(updated));
  }

  void updateAvatarUrlLocal(String avatarUrl) {
    final next = avatarUrl.trim();
    final cur = state;
    if (cur == null) return;
    final updated = UserProfile(
      id: cur.id,
      name: cur.name,
      email: cur.email,
      emailVerified: cur.emailVerified,
      avatarUrl: next,
      provider: cur.provider,
      role: cur.role,
      hasPwd: cur.hasPwd,
    );
    state = updated;
    unawaited(UserProfileStore.save(updated));
    _evictAvatarCache(updated.avatarUrl);
    _bumpAvatarRevision();
  }

  Future<UserProfile?> refresh() async {
    final gen = _generation;
    final backend = ref.read(authBackendProvider).valueOrNull ??
        AuthBackendStore.cached ??
        compileTimeAuthBackendDefault;

    // SenseCraft profile lives on the auth host (`getUserOrgInfo`). Voice
    // `/api/v1/user` expects a Voice-signed JWT; sending SenseCraft tokens
    // yields 401 (e.g. `jti` type mismatch) and can clear [AuthTokenStore].
    if (backend == AuthBackend.senseCraft) {
      final prevAvatar = state?.avatarUrl;
      // Seed the org id from the cached avatar after a cold start, so a
      // delete + relogin that spanned an app restart is still detected.
      if (_lastOrgUserId == 0) {
        _lastOrgUserId = _orgIdFromAvatarUrl(state?.avatarUrl);
      }
      final me = await ref.read(authRepositoryProvider).getMe();
      if (gen != _generation) return state;
      // SenseCraft org user_id is different from the Voice business user id.
      // A changed org id means the account was reset/recreated server-side
      // (e.g. deleted then re-registered under the same Apple identity, which
      // keeps the business login id — our DB key — stable). Treat it as a new
      // identity so the deleted account's avatar/profile is never carried over.
      final orgId = me.id;
      final identityReset =
          _lastOrgUserId != 0 && orgId > 0 && orgId != _lastOrgUserId;
      if (orgId > 0) _lastOrgUserId = orgId;
      // Generation guards stale requests; merge this profile onto current id.
      final merged = _mergeProfilePreservingDbId(
        current: state,
        fetched: me,
        identityReset: identityReset,
      );
      if (gen != _generation) return state;
      if (_sameProfile(state, merged)) return state;
      state = merged;
      unawaited(UserProfileStore.save(merged));
      // Only evict/bump when the URL actually changes — otherwise the home
      // avatar blinks (cache miss → blank → re-download) on every tab entry.
      // On an identity reset always bust so a deleted account's bitmap can't
      // linger in the image caches.
      if (identityReset || _avatarChanged(prevAvatar, merged.avatarUrl)) {
        _evictAvatarCache(prevAvatar);
        _evictAvatarCache(merged.avatarUrl);
        AvatarDecodedCache.clear();
        _bumpAvatarRevision();
        if (identityReset) {
          try {
            PaintingBinding.instance.imageCache.clear();
          } catch (_) {
            // ignore
          }
        }
      }
      return merged;
    }

    final token = AuthTokenStore.cached;
    if (token == null || token.trim().isEmpty) return state;
    final api = ref.read(userApiProvider);
    final me = await api.getMe();
    if (gen != _generation) return state;
    if (_userIdsConflict(state, me)) return state;
    final prevAvatar = state?.avatarUrl;
    if (_sameProfile(state, me)) return state;
    state = me;
    unawaited(UserProfileStore.save(me));
    if (_avatarChanged(prevAvatar, me.avatarUrl)) {
      _evictAvatarCache(prevAvatar);
      _evictAvatarCache(me.avatarUrl);
      AvatarDecodedCache.clear();
      _bumpAvatarRevision();
    }
    return me;
  }

  Future<void> clear() async {
    _generation++;
    _evictAvatarCache(state?.avatarUrl);
    AvatarDecodedCache.clear();
    state = null;
    _bumpAvatarRevision();
    try {
      PaintingBinding.instance.imageCache.clear();
    } catch (_) {
      // ignore
    }
    await UserProfileStore.clear();
  }

  /// SenseCraft org `user_id` ≠ business login user id — keep the login id so
  /// SQLite path stays stable. Never fall back to another account's fields.
  UserProfile _mergeProfilePreservingDbId({
    required UserProfile? current,
    required UserProfile fetched,
    bool identityReset = false,
  }) {
    // An identity reset (org user_id changed) forces a fresh profile even when
    // the business login id — hence [_isSameUserId] — is unchanged.
    final sameAccount = !identityReset &&
        (current == null || _isSameUserId(current, fetched));
    final keepId = (current != null && current.id > 0) ? current.id : fetched.id;
    return UserProfile(
      id: keepId,
      name: sameAccount
          ? _preferNonEmpty(fetched.name, current?.name)
          : _trimToNull(fetched.name),
      email: sameAccount
          ? _preferNonEmpty(fetched.email, current?.email)
          : _trimToNull(fetched.email),
      emailVerified: fetched.emailVerified ??
          (sameAccount ? current?.emailVerified : null),
      // Keep the last good avatar when getMe omits it — avoids a white blink
      // on home → settings while a background refresh runs. SenseCraft also
      // returns a new timestamp query on every request; retain the current URL
      // when the underlying avatar resource is unchanged so image caches hit.
      // Only within the same identity: a different/reset account must take the
      // fetched avatar (empty → default) and never resurrect the previous one.
      avatarUrl: sameAccount
          ? _preferStableAvatarUrl(fetched.avatarUrl, current?.avatarUrl)
          : _trimToNull(fetched.avatarUrl),
      provider: sameAccount
          ? _preferNonEmpty(fetched.provider, current?.provider)
          : _trimToNull(fetched.provider),
      role: fetched.role ?? (sameAccount ? current?.role : null),
      hasPwd: fetched.hasPwd ?? (sameAccount ? current?.hasPwd : null),
    );
  }

  /// SenseCraft avatar URLs embed the org user_id as a numeric path segment
  /// (`.../refer/avatar/{orgUserId}?timestamp=...`). Used to seed
  /// [_lastOrgUserId] after a cold start where only the cached profile (not the
  /// org id) is restored. Returns 0 when no numeric segment is present.
  int _orgIdFromAvatarUrl(String? url) {
    final raw = (url ?? '').trim();
    if (raw.isEmpty) return 0;
    final uri = Uri.tryParse(raw);
    if (uri == null) return 0;
    for (final seg in uri.pathSegments.reversed) {
      final n = int.tryParse(seg);
      if (n != null && n > 0) return n;
    }
    return 0;
  }

  String? _preferNonEmpty(String? primary, String? fallback) {
    final p = (primary ?? '').trim();
    if (p.isNotEmpty) return p;
    final f = (fallback ?? '').trim();
    return f.isEmpty ? null : f;
  }

  String? _trimToNull(String? value) {
    final v = (value ?? '').trim();
    return v.isEmpty ? null : v;
  }
}
