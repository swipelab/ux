import 'package:ux/src/media/design.dart';
import 'package:flutter/cupertino.dart';
import 'package:ux/src/media/touch.dart';
import 'package:ux/ux.dart';
import 'package:ux/gallery.dart';

/// Pushed inside the picker's sheet via `host?.push(...)`. Pops with
/// the chosen [XAlbum] (or `null` on back). Mirrors telegram-iOS's
/// `MediaGroupsScreen` pushed onto the modal's nav stack
/// (`MediaPickerScreen.swift:3427`, `MediaGroupsScreen.swift:152`).
class AlbumsScreen with Screen<XAlbum?>, Emitter {
  /// Creates the album list.
  AlbumsScreen({
    required this.albums,
    required this.sheetController,
    this.selectedId,
  });

  /// Pre-loaded album list — picker does the I/O and passes the
  /// snapshot in. Keeps the screen pure.
  final List<XAlbum> albums;

  /// Inherited from the picker so the inner list scroll coordinates
  /// with the sheet's pan (drag-down at scroll-top expands the
  /// sheet's drag rather than overscrolling the list).
  final SheetController sheetController;

  /// The id of the currently active album in the picker — renders a
  /// check on that row. `null` matches the "Recents" virtual row.
  final String? selectedId;

  @override
  Widget buildPresenter(BuildContext context) {
    return ColoredBox(
      color: colors.scaffold,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            _TopBar(onBack: () => pop(null)),
            Expanded(
              child: _AlbumList(
                albums: albums,
                sheetController: sheetController,
                selectedId: selectedId,
                onSelect: pop,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, top: 4, bottom: 4, right: 8),
      child: Row(
        children: [
          Touch(
            onPress: onBack,
            child: Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.surface,
              ),
              child: Icon(
                CupertinoIcons.chevron_back,
                color: colors.textPrimary,
                size: 18,
              ),
            ),
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Albums',
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  CupertinoIcons.chevron_up,
                  color: colors.textPrimary,
                  size: 14,
                ),
              ],
            ),
          ),
          const Spacer(),
          const SizedBox(width: 44),
        ],
      ),
    );
  }
}

class _AlbumList extends StatefulWidget {
  const _AlbumList({
    required this.albums,
    required this.sheetController,
    required this.selectedId,
    required this.onSelect,
  });

  final List<XAlbum> albums;
  final SheetController sheetController;
  final String? selectedId;
  final ValueChanged<XAlbum?> onSelect;

  @override
  State<_AlbumList> createState() => _AlbumListState();
}

class _AlbumListState extends State<_AlbumList> {
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.sheetController.attach(_scroll);
  }

  @override
  void dispose() {
    widget.sheetController.detach(_scroll);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: _scroll,
      physics: widget.sheetController.physics,
      padding: EdgeInsets.symmetric(vertical: space.xs),
      itemCount: widget.albums.length,
      itemBuilder: (context, index) {
        final album = widget.albums[index];
        return _AlbumRow(
          album: album,
          isSelected: album.id == widget.selectedId ||
              (album.id == 'recents' && widget.selectedId == null),
          onPress: () => widget.onSelect(album),
        );
      },
    );
  }
}

class _AlbumRow extends StatelessWidget {
  const _AlbumRow({
    required this.album,
    required this.isSelected,
    required this.onPress,
  });

  final XAlbum album;
  final bool isSelected;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    return Touch(
      fade: 0.5,
      onPress: onPress,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: space.md,
          vertical: space.xs,
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(radius.sm),
              child: SizedBox(
                width: 56,
                height: 56,
                child: ColoredBox(color: colors.fill),
              ),
            ),
            SizedBox(width: space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    album.name,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  SizedBox(height: 2),
                  Text(
                    '${album.count}',
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(
                CupertinoIcons.checkmark,
                color: colors.brand,
                size: 20,
              ),
          ],
        ),
      ),
    );
  }
}
