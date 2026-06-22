// On web, record_web ignores the sampleRate we request and silently captures
// at whatever rate the browser's AudioContext settles on (commonly 44100 or
// 48000Hz, never exposed back through record's public API) — see
// voice_assistant_provider.dart's _startMicStream for why the backend needs
// to know the real rate instead of assuming 16000. Native platforms honor
// the requested rate, so this only has a real implementation on web.
export 'web_audio_sample_rate_stub.dart'
    if (dart.library.js_interop) 'web_audio_sample_rate_web.dart';
