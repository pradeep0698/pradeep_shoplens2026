import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'presentation/screens/about_screen.dart';
import 'presentation/screens/admin_screen.dart';
import 'presentation/screens/gallery_scan_results_screen.dart';
import 'presentation/screens/gallery_scan_screen.dart';
import 'presentation/screens/live_scan_screen.dart';
import 'presentation/screens/login_screen.dart';
import 'presentation/screens/main_screen.dart';
import 'presentation/screens/profile_screen.dart';
import 'presentation/screens/scan_review_screen.dart';
import 'presentation/screens/signup_screen.dart';
import 'presentation/screens/splash_screen.dart';
import 'presentation/screens/forgot_password_screen.dart';

// Notifies GoRouter whenever Firebase Auth emits a new user state.
// GoRouter is created once and stays stable — only the redirect re-runs.
class _AuthChangeNotifier extends ChangeNotifier {
  _AuthChangeNotifier() {
    _sub = FirebaseAuth.instance.authStateChanges().listen((user) {
      // Warms the cached Firebase ID token as soon as a user is known, on both
      // fresh sign-in and session restore at launch — otherwise the first call
      // to voice-assistant (the only backend that sends an Authorization
      // header, see dio_client.dart's voiceDioProvider) pays for a real
      // network round-trip to mint a token instead of reading the cache.
      unawaited(user?.getIdToken().catchError((_) => null));
      notifyListeners();
    });
  }

  late final StreamSubscription<User?> _sub;

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final authNotifier = _AuthChangeNotifier();
  ref.onDispose(authNotifier.dispose);

  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: authNotifier,
    redirect: (context, state) {
      final isLoggedIn  = FirebaseAuth.instance.currentUser != null;
      final isSplash    = state.matchedLocation == '/splash';
      final isAuthRoute = state.matchedLocation == '/login' ||
                          state.matchedLocation == '/signup';
      final isPublicRoute = isAuthRoute ||
                            state.matchedLocation == '/about' ||
                            state.matchedLocation == '/forgot-password';

      if (isSplash)                      return isLoggedIn ? '/main' : '/login';
      if (!isLoggedIn && !isPublicRoute) return '/login';
      if (isLoggedIn  &&  isAuthRoute)   return '/main';
      return null;
    },
    routes: [
      GoRoute(path: '/splash',           builder: (_, __) => const SplashScreen()),
      GoRoute(path: '/login',            builder: (_, __) => const LoginScreen()),
      GoRoute(path: '/forgot-password',  builder: (_, __) => const ForgotPasswordScreen()),
      GoRoute(path: '/signup',           builder: (_, __) => const SignUpScreen()),
      GoRoute(path: '/main',             builder: (_, __) => const MainScreen()),
      GoRoute(path: '/profile',          builder: (_, __) => const ProfileScreen()),
      GoRoute(path: '/admin',            builder: (_, __) => const AdminScreen()),
      GoRoute(path: '/live-scan',        builder: (_, __) => const LiveScanScreen()),
      GoRoute(
        path: '/scan-review',
        builder: (_, state) => ScanReviewScreen(args: state.extra as ScanReviewArgs),
      ),
      GoRoute(
        path: '/gallery-scan',
        builder: (_, state) => GalleryScanScreen(args: state.extra as ScanReviewArgs),
      ),
      GoRoute(path: '/gallery-scan-results', builder: (_, __) => const GalleryScanResultsScreen()),
      GoRoute(path: '/about',            builder: (_, __) => const AboutScreen()),
    ],
  );
});

class ShopLensApp extends ConsumerWidget {
  const ShopLensApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title:        'ShopLens',
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      theme: ThemeData(
        colorScheme: const ColorScheme.dark(
          primary:   Color(0xFF34D399),
          secondary: Color(0xFF6EE7B7),
          surface:   Color(0xFF1E293B),
          error:     Color(0xFFF87171),
          onPrimary: Color(0xFF0F172A),
          onSurface: Colors.white,
        ),
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        fontFamily: 'Inter',
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0F172A),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        snackBarTheme: const SnackBarThemeData(
          backgroundColor: Color(0xFF1E293B),
          contentTextStyle: TextStyle(color: Colors.white),
        ),
      ),
    );
  }
}
