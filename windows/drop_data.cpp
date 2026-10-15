#include "drop_data.h"

#include <shellapi.h>
#include <shlobj.h>
#include <wrl/client.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cwchar>
#include <utility>

namespace ux {

namespace {

using Microsoft::WRL::ComPtr;

CLIPFORMAT Format(const wchar_t* name) { return static_cast<CLIPFORMAT>(RegisterClipboardFormatW(name)); }

FORMATETC Request(CLIPFORMAT format, LONG index, DWORD media) {
  return {format, nullptr, DVASPECT_CONTENT, index, media};
}

// The descriptors of [data]'s CFSTR_FILEDESCRIPTORW, or none when it has none
// or they overrun their memory.
std::optional<std::vector<FILEDESCRIPTORW>> Descriptors(IDataObject* data) {
  FORMATETC request = Request(Format(CFSTR_FILEDESCRIPTORW), -1, TYMED_HGLOBAL);
  STGMEDIUM medium;
  if (FAILED(data->GetData(&request, &medium))) return std::nullopt;
  std::optional<std::vector<FILEDESCRIPTORW>> descriptors;
  const SIZE_T size = GlobalSize(medium.hGlobal);
  constexpr SIZE_T head = offsetof(FILEGROUPDESCRIPTORW, fgd);
  if (const auto* group = static_cast<const FILEGROUPDESCRIPTORW*>(GlobalLock(medium.hGlobal))) {
    if (size >= head && (size - head) / sizeof(FILEDESCRIPTORW) >= group->cItems) {
      descriptors.emplace(group->fgd, group->fgd + group->cItems);
    }
    GlobalUnlock(medium.hGlobal);
  }
  ReleaseStgMedium(&medium);
  return descriptors;
}

// Whether Windows reserves [stem], the part of a name before its first dot,
// for a device.
bool DeviceStem(std::wstring stem) {
  stem.erase(stem.find_last_not_of(L' ') + 1);
  CharUpperBuffW(stem.data(), static_cast<DWORD>(stem.size()));
  if (stem == L"CON" || stem == L"PRN" || stem == L"AUX" || stem == L"NUL") return true;
  if (stem.size() != 4 || (stem.compare(0, 3, L"COM") != 0 && stem.compare(0, 3, L"LPT") != 0)) return false;
  const wchar_t port = stem[3];
  // The digits, and superscript one, two and three.
  return (port >= L'0' && port <= L'9') || port == 0xB9 || port == 0xB2 || port == 0xB3;
}

// The name of the copy of a virtual file named [descriptor_name]; none when
// nothing of it is left.
std::optional<std::wstring> CopyName(const std::wstring& descriptor_name) {
  std::wstring name = descriptor_name.substr(descriptor_name.find_last_of(L"\\/") + 1);
  for (wchar_t& c : name) {
    if (c < L' ' || std::wcschr(L"<>:\"|?*", c) != nullptr) c = L'_';
  }
  name.erase(name.find_last_not_of(L". ") + 1);
  if (name.empty()) return std::nullopt;
  if (DeviceStem(name.substr(0, name.find(L'.')))) name.insert(0, 1, L'_');
  return name;
}

// GetTempPathW's directory followed by ux_drops.
std::optional<std::wstring> DropsRoot() {
  wchar_t temp[MAX_PATH + 1];
  const DWORD length = GetTempPathW(MAX_PATH + 1, temp);
  if (length == 0 || length > MAX_PATH) return std::nullopt;
  return std::wstring(temp, length) + L"ux_drops";
}

// A fresh GUID as 36 characters, without braces.
std::optional<std::wstring> NewGuid() {
  GUID guid;
  if (FAILED(CoCreateGuid(&guid))) return std::nullopt;
  wchar_t text[39];
  if (StringFromGUID2(guid, text, 39) == 0) return std::nullopt;
  return std::wstring(text + 1, 36);
}

bool WriteAll(HANDLE file, const BYTE* bytes, SIZE_T length) {
  while (length > 0) {
    DWORD written = 0;
    const DWORD chunk = static_cast<DWORD>(std::min<SIZE_T>(length, 1 << 20));
    if (!WriteFile(file, bytes, chunk, &written, nullptr)) return false;
    bytes += written;
    length -= written;
  }
  return true;
}

// Writes [global]'s bytes into [file], at most [size] of them when the
// descriptor gives a size, since a block may be larger than what it holds.
bool WriteGlobal(HANDLE file, HGLOBAL global, std::optional<uint64_t> size) {
  SIZE_T length = GlobalSize(global);
  if (size) length = static_cast<SIZE_T>(std::min<uint64_t>(length, *size));
  if (length == 0) return true;
  const auto* bytes = static_cast<const BYTE*>(GlobalLock(global));
  if (bytes == nullptr) return false;
  const bool written = WriteAll(file, bytes, length);
  GlobalUnlock(global);
  return written;
}

// Writes [stream] from its start into [file]; a stream that cannot seek is
// read from where it stands.
bool WriteStream(HANDLE file, IStream* stream) {
  const LARGE_INTEGER start = {};
  stream->Seek(start, STREAM_SEEK_SET, nullptr);
  std::vector<BYTE> buffer(1 << 16);
  while (true) {
    ULONG read = 0;
    if (FAILED(stream->Read(buffer.data(), static_cast<ULONG>(buffer.size()), &read))) return false;
    if (read == 0) return true;
    if (!WriteAll(file, buffer.data(), read)) return false;
  }
}

// Writes [medium]'s contents to a new file at [path]: a storage as a compound
// file, a block or a stream as its bytes.
bool WriteContents(const std::wstring& path, const STGMEDIUM& medium, std::optional<uint64_t> size) {
  if (medium.tymed == TYMED_ISTORAGE) {
    ComPtr<IStorage> copy;
    return SUCCEEDED(StgCreateStorageEx(path.c_str(), STGM_CREATE | STGM_READWRITE | STGM_SHARE_EXCLUSIVE,
                                        STGFMT_STORAGE, 0, nullptr, nullptr, IID_PPV_ARGS(&copy))) &&
           SUCCEEDED(medium.pstg->CopyTo(0, nullptr, nullptr, copy.Get())) && SUCCEEDED(copy->Commit(STGC_DEFAULT));
  }
  const HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  const bool written =
      medium.tymed == TYMED_HGLOBAL ? WriteGlobal(file, medium.hGlobal, size) : WriteStream(file, medium.pstm);
  CloseHandle(file);
  return written;
}

// Writes [medium] to `<root>\<GUID>\<name>`, and answers the path; none, with
// the directory removed, when it cannot be written.
std::optional<std::wstring> WriteCopy(const std::wstring& root, const std::wstring& name, const STGMEDIUM& medium,
                                      std::optional<uint64_t> size) {
  const std::optional<std::wstring> id = NewGuid();
  if (!id) return std::nullopt;
  const std::wstring dir = root + L"\\" + *id;
  if (!CreateDirectoryW(dir.c_str(), nullptr)) return std::nullopt;
  const std::wstring path = dir + L"\\" + name;
  if (WriteContents(path, medium, size)) return path;
  DeleteFileW(path.c_str());
  RemoveDirectoryW(dir.c_str());
  return std::nullopt;
}

}  // namespace

LogicalPoint ToLogical(HWND view, POINTL screen, UINT dpi) {
  POINT client = {screen.x, screen.y};
  ScreenToClient(view, &client);
  const double scale = dpi / 96.0;
  return {client.x / scale, client.y / scale};
}

bool OffersFiles(IDataObject* data) {
  FORMATETC drop = Request(CF_HDROP, -1, TYMED_HGLOBAL);
  FORMATETC descriptors = Request(Format(CFSTR_FILEDESCRIPTORW), -1, TYMED_HGLOBAL);
  return data->QueryGetData(&drop) == S_OK || data->QueryGetData(&descriptors) == S_OK;
}

std::vector<std::wstring> PathsOf(HDROP drop) {
  std::vector<std::wstring> paths;
  const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  for (UINT i = 0; i < count; i++) {
    std::wstring path(DragQueryFileW(drop, i, nullptr, 0), L'\0');
    DragQueryFileW(drop, i, path.data(), static_cast<UINT>(path.size() + 1));
    paths.push_back(std::move(path));
  }
  return paths;
}

std::optional<std::vector<std::wstring>> DroppedPaths(IDataObject* data) {
  FORMATETC request = Request(CF_HDROP, -1, TYMED_HGLOBAL);
  STGMEDIUM medium;
  if (FAILED(data->GetData(&request, &medium))) return std::nullopt;
  std::vector<std::wstring> paths = PathsOf(static_cast<HDROP>(medium.hGlobal));
  ReleaseStgMedium(&medium);
  return paths;
}

std::vector<DroppedFile> DescribePaths(const std::vector<std::wstring>& paths) {
  std::vector<DroppedFile> files;
  for (const std::wstring& path : paths) {
    const DWORD attributes = GetFileAttributesW(path.c_str());
    const bool directory = attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
    files.push_back({path, path.substr(path.find_last_of(L'\\') + 1), false, directory});
  }
  return files;
}

std::vector<DroppedFile> WriteVirtualFiles(IDataObject* data) {
  std::vector<DroppedFile> copies;
  const std::optional<std::vector<FILEDESCRIPTORW>> descriptors = Descriptors(data);
  const std::optional<std::wstring> root = DropsRoot();
  if (!descriptors || !root) return copies;
  if (!CreateDirectoryW(root->c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) return copies;
  const CLIPFORMAT contents = Format(CFSTR_FILECONTENTS);
  for (size_t i = 0; i < descriptors->size(); i++) {
    const FILEDESCRIPTORW& descriptor = (*descriptors)[i];
    if ((descriptor.dwFlags & FD_ATTRIBUTES) != 0 && (descriptor.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
      continue;
    }
    const std::optional<std::wstring> name =
        CopyName(std::wstring(descriptor.cFileName, wcsnlen(descriptor.cFileName, MAX_PATH)));
    if (!name) continue;
    FORMATETC request = Request(contents, static_cast<LONG>(i), TYMED_HGLOBAL | TYMED_ISTREAM | TYMED_ISTORAGE);
    STGMEDIUM medium;
    if (FAILED(data->GetData(&request, &medium))) continue;
    std::optional<uint64_t> size;
    if ((descriptor.dwFlags & FD_FILESIZE) != 0) {
      size = (static_cast<uint64_t>(descriptor.nFileSizeHigh) << 32) | descriptor.nFileSizeLow;
    }
    std::optional<std::wstring> path = WriteCopy(*root, *name, medium, size);
    ReleaseStgMedium(&medium);
    if (path) copies.push_back({std::move(*path), *name, true, false});
  }
  return copies;
}

}  // namespace ux
