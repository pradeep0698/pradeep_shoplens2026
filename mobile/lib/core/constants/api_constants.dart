class ApiConstants {
  // TEMPORARY: hardcoded to the dev Cloud Run URLs to unblock testing while
  // the .env / GitHub Environment variable pipeline is being debugged.
  static const String analyzerBaseUrl = 'https://ai-analyzer-82592393149.us-central1.run.app';
  static const String matcherBaseUrl  = 'https://product-matcher-82592393149.us-central1.run.app';
  static const String stateBaseUrl    = 'https://state-manager-82592393149.us-central1.run.app';
}
