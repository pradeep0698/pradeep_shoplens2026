import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'firebase_options.dart';

// Top-level function required by FCM — only registered on physical Android devices.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
}

bool get _isEmulator {
  // flutter_test sets this; at runtime it's always false on a real device.
  // android.os.Build.FINGERPRINT contains "generic" on emulators.
  // We use a compile-time constant so tree-shaking removes the block on release.
  return const bool.fromEnvironment('FLUTTER_TEST', defaultValue: false);
}

// TEMPORARY: surfaces the real exception text on-screen instead of a blank
// release-mode ErrorWidget, to diagnose the iOS grey-screen issue without
// device console access. Remove once that's resolved.
void _installDiagnosticErrorWidget() {
  ErrorWidget.builder = (FlutterErrorDetails details) => Material(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              details.exceptionAsString(),
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          ),
        ),
      );
}

void main() {
  _installDiagnosticErrorWidget();
  // Only a startup failure (before runApp below) should take over the whole
  // screen — any later uncaught async error (e.g. a fire-and-forget call
  // elsewhere in the app) must not blank out an already-running app.
  var started = false;
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await dotenv.load(fileName: '.env');
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    FirebaseFirestore.instance.settings = const Settings(persistenceEnabled: false);

    // TEMPORARY: local Auth/Firestore emulators, used while shoplens-dev-499700
    // is inaccessible (see firebase.json's `emulators` block for ports). Remove
    // once real project access is restored.
    if (dotenv.env['USE_FIREBASE_EMULATOR'] == 'true') {
      const host = kIsWeb ? 'localhost' : '127.0.0.1';
      await FirebaseAuth.instance.useAuthEmulator(host, 9099);
      FirebaseFirestore.instance.useFirestoreEmulator(host, 8090);
    }

    // FCM background handler spawns a second Flutter engine — skip on web and
    // when running with --dart-define=NO_FCM=true (useful for emulators).
    const skipFcm = bool.fromEnvironment('NO_FCM', defaultValue: false);
    if (!kIsWeb && !skipFcm) {
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
      await FirebaseMessaging.instance.requestPermission();
    }

    runApp(const ProviderScope(child: ShopLensApp()));
    started = true;
  }, (error, stack) {
    if (started) {
      debugPrint('Uncaught async error after startup: $error\n$stack');
      return;
    }
    runApp(MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text('$error\n\n$stack', style: const TextStyle(color: Colors.redAccent, fontSize: 11)),
          ),
        ),
      ),
    ));
  });
}
