import 'dart:io' as io;
import 'dart:typed_data';

/// Outgoing media carrier. Every producer (camera, picker, file-pick,
/// clipboard paste, voice recorder) emits one of these; every send-path
/// consumes one. Unifies the prior `CameraResult` / `PickedAsset` /
/// `(file, isVideo)` records, and pairs with `dialog_bloc.sendMedia`
/// (a sealed-switch dispatcher) to replace the four parallel send
/// methods.
///
/// The kind is encoded as the sealed variant (`ImageMedia` /
/// `VideoMedia` / `FileMedia` / `AudioMedia`) — pattern-match
/// exhaustiveness lets the compiler enforce dispatcher coverage.
sealed class XMedia {
  const XMedia(
      {required this.file, this.bookmark, this.name, this.isTemporaryCopy = false});

  /// Local file to read and upload. Always present.
  final io.File file;

  /// Security-scoped bookmark from `XFiles.pick` (iOS/macOS) or
  /// content-URI bytes (Android). Persisted in `pending_uploads.bookmark`
  /// so a cold-restart upload can re-acquire sandbox access. Null for
  /// in-sandbox files (camera, gallery, paste).
  final Uint8List? bookmark;

  /// User-facing filename from the picker's display name (`XPickedFile.name`),
  /// when known. Preferred over the source path's basename for `FileInfo.name`:
  /// on Android the SAF picker stream-copies the content URI to a
  /// `<appCache>/ux_pick/{ts}_{name}` temp, so the path basename is mangled
  /// with a timestamp. Null for camera/gallery/paste (no display name).
  final String? name;

  /// True when [file] is an app-owned ephemeral copy the picker made for us
  /// (`XPickedFile.isTemporaryCopy` — the Android SAF picker copies a
  /// `content://` source into the app cache). The upload promotes such a source
  /// into the managed cache after upload instead of recording a source row that
  /// points at the soon-cleared temp. False for durable user-chosen paths.
  final bool isTemporaryCopy;
}

/// A still image.
final class ImageMedia extends XMedia {
  /// Creates an image carrier.
  const ImageMedia(
      {required super.file, super.bookmark, super.name, super.isTemporaryCopy});
}

/// A video.
final class VideoMedia extends XMedia {
  /// Creates a video carrier.
  const VideoMedia(
      {required super.file, super.bookmark, super.name, super.isTemporaryCopy});
}

/// A file of any other kind.
final class FileMedia extends XMedia {
  /// Creates a file carrier.
  const FileMedia(
      {required super.file, super.bookmark, super.name, super.isTemporaryCopy});
}

/// An audio recording or file.
final class AudioMedia extends XMedia {
  /// Creates an audio carrier.
  const AudioMedia(
      {required super.file, super.bookmark, super.name, super.isTemporaryCopy});
}
