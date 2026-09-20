/// Which view a [PickerGridItem] is rendered in. Combined with the
/// asset id in [PickerSourceRegistry] so grid and strip cells for the
/// same `XAsset.id` resolve independently. The picker's
/// `transitionSourceFor` closure reads its current `_displayMode` and
/// picks the cell currently visible to the user — telegram's
/// `selectionNode.alpha > 0.0` routing translated into a Dart record
/// key.
enum PickerViewKind {
  /// The grid of all assets.
  grid,

  /// The strip of picked assets.
  strip,
}
