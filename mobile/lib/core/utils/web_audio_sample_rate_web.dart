import 'package:web/web.dart' as web;

/// Creates a throwaway AudioContext purely to read the sample rate the
/// browser will actually use for audio I/O — record_web's getUserMedia-backed
/// AudioContext lands on this same rate, but never reports it back through
/// record's public API.
int? probeWebMicSampleRate() {
  try {
    final ctx = web.AudioContext();
    final rate = ctx.sampleRate.toInt();
    ctx.close();
    return rate;
  } catch (_) {
    return null;
  }
}
