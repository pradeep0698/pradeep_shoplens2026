String mergeTranscriptFragment(String current, String incoming) {
  if (current.isEmpty) return incoming;
  if (incoming.isEmpty) return current;

  final currentTrimmed = current.trim();
  final incomingTrimmed = incoming.trim();
  if (incomingTrimmed.startsWith(currentTrimmed)) return incoming.trimLeft();
  if (currentTrimmed.startsWith(incomingTrimmed)) return current;

  final maxOverlap = current.length < incoming.length
      ? current.length
      : incoming.length;
  for (var length = maxOverlap; length > 0; length--) {
    if (current.endsWith(incoming.substring(0, length))) {
      return '$current${incoming.substring(length)}';
    }
  }
  return '$current$incoming';
}
