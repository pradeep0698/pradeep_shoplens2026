import 'package:cloud_firestore/cloud_firestore.dart';
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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseFirestore.instance.settings = const Settings(persistenceEnabled: false);

  // FCM background handler spawns a second Flutter engine — skip on web and
  // when running with --dart-define=NO_FCM=true (useful for emulators).
  const skipFcm = bool.fromEnvironment('NO_FCM', defaultValue: false);
  if (!kIsWeb && !skipFcm) {
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    await FirebaseMessaging.instance.requestPermission();
  }

  runApp(const ProviderScope(child: ShopLensApp()));
}
