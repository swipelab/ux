#ifndef UX_DROP_DATA_H_
#define UX_DROP_DATA_H_

#include <windows.h>

#include <objidl.h>

#include <optional>
#include <string>
#include <vector>

namespace ux {

// A dropped file as `ux/drop/events` reports it.
struct DroppedFile {
  std::wstring path;
  std::wstring name;
  // Whether [path] is a copy written for a virtual file, which the app owns.
  bool is_temporary_copy;
  bool is_directory;
};

// A point in Flutter's global logical coordinates.
struct LogicalPoint {
  double x;
  double y;
};

// [screen], a point on the screen, in [view]'s client area in logical pixels:
// physical pixels divided by the scale of [dpi].
LogicalPoint ToLogical(HWND view, POINTL screen, UINT dpi);

// Whether [data] offers files: CF_HDROP, or virtual files as
// CFSTR_FILEDESCRIPTORW with CFSTR_FILECONTENTS.
bool OffersFiles(IDataObject* data);

// The paths of [data]'s CF_HDROP, or none when it has none.
std::optional<std::vector<std::wstring>> DroppedPaths(IDataObject* data);

// The files at [paths], each a directory or not as the file system has it.
std::vector<DroppedFile> DescribePaths(const std::vector<std::wstring>& paths);

// Writes each virtual file that [data] offers as CFSTR_FILEDESCRIPTORW with
// CFSTR_FILECONTENTS to a copy at `ux_drops\<GUID>\<name>` under GetTempPathW,
// in a fresh directory for each, and answers the copies in the descriptors'
// order. <name> is the last component of the descriptor's name, with the
// characters a file name cannot hold replaced by `_` and `_` before a device
// name. A directory's descriptor has no contents and gives no copy, nor does a
// file whose contents cannot be read or written, whose directory is removed.
std::vector<DroppedFile> WriteVirtualFiles(IDataObject* data);

}  // namespace ux

#endif  // UX_DROP_DATA_H_
