import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:ux/ux.dart';

void main() => runApp(MyApp());

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  String _platformVersion = 'Unknown';

  @override
  void initState() {
    super.initState();
    initPlatformState();
  }

  // Platform messages are asynchronous, so we initialize in an async method.
  Future<void> initPlatformState() async {
    String platformVersion;
    // Platform messages may fail, so we use a try/catch PlatformException.
    try {
      platformVersion = await UX.platformVersion;
    } on PlatformException {
      platformVersion = 'Failed to get platform version.';
    }

    if (!mounted) return;

    setState(() {
      _platformVersion = platformVersion;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      routes: {
        '/': (context) => Scaffold(
              appBar: AppBar(
                title: const Text('Plugin example app'),
              ),
              body: Builder(
                builder: (context) => ListView(
                  padding: EdgeInsets.only(top: 48),
                  children: [
                    ListTile(title: Text('Running on: $_platformVersion\n')),
                    ListTile(
                      title: Text('Show a simple note'),
                      //onTap: () => context.showText('This is a simple note'),
                    ),
                    ListTile(
                      title: Text('Show modal note'),
                      //onTap: () => context.showText('This is a modal note', backdropBlur: 6, modal: true),
                    )
                  ],
                ),
              ),
            )
      },
    );
  }
}
