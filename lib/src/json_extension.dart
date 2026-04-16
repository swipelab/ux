/// Signature for a function that converts a JSON map to a typed object.
typedef JsonConvert<T> = T Function(Map<String, dynamic> json);

/// Utilities for converting JSON structures to typed Dart objects.
class Json {
  /// Converts a JSON list of maps to a typed `List<T>`.
  ///
  /// Returns an empty list if [json] is null.
  static List<T> list<T>(List? json, JsonConvert<T> fromJson) => json == null
      ? []
      : json.cast<Map<String, dynamic>>().map(fromJson).toList();

  /// Converts a JSON map of maps to a typed `Map<String, T>`.
  ///
  /// Returns an empty map if [json] is null.
  static Map<String, T> map<T>(Map? json, JsonConvert<T> fromJson) =>
      json == null
          ? {}
          : Map.fromEntries(
              json.entries.map((e) => MapEntry(e.key, fromJson(e.value))));

  /// Reads a value at a dot-separated [path] from a nested JSON structure.
  ///
  /// Supports both map keys and list indices (numeric segments).
  /// Returns [defaultValue] if the path doesn't exist.
  static dynamic path<T>(Map<String, dynamic> json, String path,
      {dynamic defaultValue}) {
    try {
      dynamic current = json;
      path.split('.').forEach((segment) {
        final index = int.tryParse(segment);
        if (index != null && current is List<dynamic>) {
          current = current[index];
        } else if (current is Map<String, dynamic>) {
          current = current[segment];
        }
      });
      return current ?? defaultValue;
    } catch (error) {
      return defaultValue;
    }
  }
}
