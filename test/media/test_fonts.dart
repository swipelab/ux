import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

Future<void> loadMediaTestFonts() async {
  final config = File('.dart_tool/package_config.json');
  final packages =
      (jsonDecode(config.readAsStringSync()) as Map)['packages'] as List;
  Uri root(String name) => config.absolute.uri.resolve(
    '${packages.cast<Map>().singleWhere((p) => p['name'] == name)['rootUri']}/',
  );
  final flutter = root('flutter');
  final roboto = FontLoader('Roboto');
  for (final weight in ['Regular', 'Bold']) {
    roboto.addFont(
      File.fromUri(
        flutter.resolve(
          '../../bin/cache/artifacts/material_fonts/Roboto-$weight.ttf',
        ),
      ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
    );
  }
  await roboto.load();
  final icons = root('cupertino_icons').resolve('assets/CupertinoIcons.ttf');
  await (FontLoader('packages/cupertino_icons/CupertinoIcons')
        ..addFont(File.fromUri(icons).readAsBytes().then(ByteData.sublistView)))
      .load();
}
