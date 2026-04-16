import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:ux/ux.dart';

void main() => runApp(MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: ChatScreen(),
    ));

/// Demonstrates UxKeyboard in a chat UI:
/// - Frame-accurate keyboard height tracking (no Flutter viewInsets lag)
/// - Interactive dismiss (swipe the keyboard down like iMessage)
/// - Scroll freeze while the user is panning the keyboard
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _keyboard = UxKeyboard.instance;
  final _textController = TextEditingController();
  final _messages = List.generate(30, (i) => 'Message ${i + 1}');

  @override
  void initState() {
    super.initState();
    // trackingInset: height of the input bar, so the pan-to-dismiss gesture
    // activates when the finger enters the keyboard zone below the input bar.
    _keyboard.enableInteractiveDismiss(trackingInset: 56);
  }

  @override
  void dispose() {
    _keyboard.disableInteractiveDismiss();
    _textController.dispose();
    super.dispose();
  }

  void _send() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    setState(() => _messages.add(text));
    _textController.clear();
  }

  @override
  Widget build(BuildContext context) {
    // Disable Flutter's built-in resize — we handle it ourselves.
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(title: Text('UxKeyboard Chat')),
      // ListenableBuilder rebuilds only when UxKeyboard notifies (height changes).
      body: ListenableBuilder(
        listenable: _keyboard,
        builder: (context, _) {
          final keyboardHeight = _keyboard.height;
          final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
          final bottom = math.max(keyboardHeight, safeBottom);

          return Column(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => FocusScope.of(context).unfocus(),
                  child: ListView.builder(
                    // Freeze scrolling while the user is panning the keyboard down.
                    // This prevents the list from bouncing during interactive dismiss.
                    reverse: true,
                    physics: _keyboard.isTracking
                        ? NeverScrollableScrollPhysics()
                        : null,
                    padding: EdgeInsets.only(top: 16, bottom: 8),
                    itemCount: _messages.length,
                    itemBuilder: (context, i) {
                      final isMe = i % 3 == 0;
                      return Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        child: Align(
                          alignment: isMe
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            constraints: BoxConstraints(
                              maxWidth: MediaQuery.sizeOf(context).width * 0.75,
                            ),
                            padding: EdgeInsets.symmetric(
                                horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: isMe
                                  ? Theme.of(context).colorScheme.primaryContainer
                                  : Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Text(_messages[i]),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              // Input bar — sits directly above the keyboard.
              Container(
                padding: EdgeInsets.only(
                  left: 12,
                  right: 4,
                  top: 8,
                  bottom: 8 + bottom,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  border: Border(
                    top: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _textController,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        decoration: InputDecoration(
                          hintText: 'Type a message...',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          isDense: true,
                        ),
                      ),
                    ),
                    SizedBox(width: 4),
                    IconButton(
                      icon: Icon(Icons.send),
                      color: Theme.of(context).colorScheme.primary,
                      onPressed: _send,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
