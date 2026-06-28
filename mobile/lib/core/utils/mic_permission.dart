import 'package:permission_handler/permission_handler.dart';

// permission_handler's native side throws (surfacing as a PlatformException /
// StandardMethodCodec.decode Envelope error) if request() is called again
// while a request for the same permission is still in flight — concurrent
// callers must await the same Future instead of issuing parallel calls.
Future<PermissionStatus>? _pendingMicRequest;

Future<PermissionStatus> requestMicrophonePermission() {
  return _pendingMicRequest ??= Permission.microphone.request().whenComplete(() {
    _pendingMicRequest = null;
  });
}
