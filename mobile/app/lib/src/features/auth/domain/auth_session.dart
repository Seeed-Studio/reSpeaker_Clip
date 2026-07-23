class AuthSession {
  final bool isLoggedIn;
  final String? email;
  final bool needsSetPassword;

  const AuthSession({
    required this.isLoggedIn,
    required this.email,
    required this.needsSetPassword,
  });

  factory AuthSession.loggedOut() => const AuthSession(isLoggedIn: false, email: null, needsSetPassword: false);

  AuthSession copyWith({
    bool? isLoggedIn,
    String? email,
    bool? needsSetPassword,
  }) {
    return AuthSession(
      isLoggedIn: isLoggedIn ?? this.isLoggedIn,
      email: email ?? this.email,
      needsSetPassword: needsSetPassword ?? this.needsSetPassword,
    );
  }
}

