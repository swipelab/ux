import 'package:flutter/material.dart';
import 'package:ux/ux.dart';

void main() => runApp(MaterialApp(home: KeyboardExample()));

class KeyboardExample extends StatefulWidget {
  @override
  State<KeyboardExample> createState() => _KeyboardExampleState();
}

class _KeyboardExampleState extends State<KeyboardExample> {
  final _keyboard = UxKeyboard.instance;
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _keyboard.addListener(_onKeyboard);
    _keyboard.enableInteractiveDismiss(trackingInset: 56);
  }

  @override
  void dispose() {
    _keyboard.removeListener(_onKeyboard);
    _keyboard.disableInteractiveDismiss();
    _focusNode.dispose();
    super.dispose();
  }

  void _onKeyboard() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final bottomInset = _keyboard.height;
    final safeArea = MediaQuery.paddingOf(context).bottom;
    final bottom = bottomInset > 0 ? bottomInset : safeArea;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(title: Text('UxKeyboard')),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              reverse: true,
              padding: EdgeInsets.only(bottom: 60 + bottom, top: 16),
              itemCount: 30,
              itemBuilder: (context, i) => Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Align(
                  alignment: i % 3 == 0 ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: i % 3 == 0 ? Colors.blue[100] : Colors.grey[200],
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text('Message ${30 - i}'),
                  ),
                ),
              ),
            ),
          ),
          Container(
            padding: EdgeInsets.only(
              left: 12,
              right: 12,
              top: 8,
              bottom: 8 + bottom,
            ),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(top: BorderSide(color: Colors.grey[300]!)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    focusNode: _focusNode,
                    decoration: InputDecoration(
                      hintText: 'Type a message...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      isDense: true,
                    ),
                  ),
                ),
                SizedBox(width: 8),
                IconButton(
                  icon: Icon(Icons.send, color: Colors.blue),
                  onPressed: () {},
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
