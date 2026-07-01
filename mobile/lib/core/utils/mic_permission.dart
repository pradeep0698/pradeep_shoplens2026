import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

// permission_handler's native side throws (surfacing as a PlatformException /
// StandardMethodCodec.decode Envelope error) if request() is called again
// while a request for the same permission is still in flight — concurrent
// callers must await the same Future instead of issuing parallel calls.
Future<PermissionStatus>? _pendingMicRequest;

Future<PermissionStatus> requestMicrophonePermission() {
  return _pendingMicRequest ??= _requestMic().whenComplete(() {
    _pendingMicRequest = null;
  });
}

Future<PermissionStatus> _requestMic() async {
  try {
    return await Permission.microphone.request();
  } on PlatformException {
    // request() throws if the native side has a pending request from a prior
    // Dart session (hot restart / cache clear). Read the current status instead
    // — sufficient to decide whether to proceed or show the error state.
    return Permission.microphone.status;
  }
}
