import 'package:flutter_test/flutter_test.dart';
import 'package:shoplens/core/utils/transcript_fragment_merger.dart';

void main() {
  test('appends delta fragments', () {
    expect(mergeTranscriptFragment('Hello ', 'there!'), 'Hello there!');
  });

  test('replaces a partial caption with its cumulative caption', () {
    expect(mergeTranscriptFragment('Hello there', 'Hello there!'), 'Hello there!');
  });

  test('does not duplicate a shorter repeated final caption', () {
    expect(mergeTranscriptFragment('Hello there!', 'Hello there'), 'Hello there!');
  });

  test('removes overlap between adjacent fragments', () {
    expect(mergeTranscriptFragment('wireless head', 'headphones'), 'wireless headphones');
  });
}
