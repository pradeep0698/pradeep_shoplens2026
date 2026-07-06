// Conditional export mirrors the pattern already used for
// voice_audio_player_native.dart/_web.dart and
// web_audio_sample_rate_stub.dart/_web.dart — dart.library.js_interop is
// only present on the web compiler, so this picks the web-only
// implementation there and the native (dart:io-capable) one everywhere else.
export 'voice_transport_selector_native.dart'
    if (dart.library.js_interop) 'voice_transport_selector_web.dart';
