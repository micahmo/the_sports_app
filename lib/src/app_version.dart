/// This build's version, e.g. "1.0.80". Release builds get it from the
/// workflow (--dart-define=APP_VERSION); local builds have none.
const String appVersion = String.fromEnvironment('APP_VERSION');
