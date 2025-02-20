typedef T _JsonConvert<T>(Map<String, dynamic> json);

class Json {
  static List<T> list<T>(List? json, _JsonConvert<T> fromJson) => json == null
      ? []
      : json.cast<Map<String, dynamic>>().map(fromJson).toList();

  static Map<String, T> map<T>(Map? json, _JsonConvert<T> fromJson) => json == null
      ? {}
      : Map.fromEntries(
          json.entries.map((e) => MapEntry(e.key, fromJson(e.value))));

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
      print(error);
      return defaultValue;
    }
  }
}
