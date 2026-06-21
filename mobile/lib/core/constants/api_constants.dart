class ApiConstants {
  // TEMPORARY: hardcoded to the dev Cloud Run URLs to unblock testing while
  // the .env / GitHub Environment variable pipeline is being debugged.
  // Project shoplens-dev-499700, project number 935092313069 — see
  // docs/local-setup.md section 8 for the canonical service URLs.
  static const String analyzerBaseUrl = 'https://ai-analyzer-935092313069.us-central1.run.app';
  static const String matcherBaseUrl  = 'https://product-matcher-935092313069.us-central1.run.app';
  static const String stateBaseUrl    = 'https://state-manager-935092313069.us-central1.run.app';
}
