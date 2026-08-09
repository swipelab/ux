import 'package:flutter/widgets.dart';

/// A non-widget object that knows how to render itself.
mixin Presenter {
  /// Builds this object's visual representation.
  Widget buildPresenter(BuildContext context);
}
