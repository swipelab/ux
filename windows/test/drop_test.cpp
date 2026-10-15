#include <windows.h>

#include <unknwn.h>

#include <objidl.h>
#include <shlobj.h>
#include <winrt/base.h>
#include <wrl/client.h>

#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "../drop_data.h"
#include "check.h"

using Microsoft::WRL::ComPtr;

namespace {

// A virtual file a source offers: its descriptor's name and its contents in
// [medium], or a directory, which has no medium.
struct Offered {
  std::wstring name;
  std::optional<DWORD> medium;
  std::string contents;
};

// A block holding [length] bytes from [bytes], then [padding] more.
HGLOBAL Global(const void* bytes, SIZE_T length, SIZE_T padding) {
  const HGLOBAL global = GlobalAlloc(GMEM_MOVEABLE, length + padding);
  auto* block = static_cast<BYTE*>(GlobalLock(global));
  std::memcpy(block, bytes, length);
  std::memset(block + length, 0x55, padding);
  GlobalUnlock(global);
  return global;
}

// A drag source's data that offers [files] as virtual files:
// CFSTR_FILEDESCRIPTORW with CFSTR_FILECONTENTS.
class VirtualFiles : public winrt::implements<VirtualFiles, IDataObject> {
 public:
  explicit VirtualFiles(std::vector<Offered> files) : files_(std::move(files)) {}

  HRESULT __stdcall GetData(FORMATETC* format, STGMEDIUM* medium) noexcept final {
    *medium = {};
    if (format->cfFormat == descriptors_) {
      std::vector<BYTE> group(offsetof(FILEGROUPDESCRIPTORW, fgd) + files_.size() * sizeof(FILEDESCRIPTORW));
      auto* header = reinterpret_cast<FILEGROUPDESCRIPTORW*>(group.data());
      header->cItems = static_cast<UINT>(files_.size());
      for (size_t i = 0; i < files_.size(); i++) {
        FILEDESCRIPTORW& d = header->fgd[i];
        wcscpy_s(d.cFileName, files_[i].name.c_str());
        d.dwFlags = FD_ATTRIBUTES | FD_FILESIZE;
        d.dwFileAttributes = files_[i].medium ? FILE_ATTRIBUTE_NORMAL : FILE_ATTRIBUTE_DIRECTORY;
        d.nFileSizeLow = static_cast<DWORD>(files_[i].contents.size());
      }
      medium->tymed = TYMED_HGLOBAL;
      medium->hGlobal = Global(group.data(), group.size(), 0);
      return S_OK;
    }
    if (format->cfFormat != contents_ || format->lindex < 0 || static_cast<size_t>(format->lindex) >= files_.size()) {
      return DV_E_FORMATETC;
    }
    const Offered& file = files_[format->lindex];
    if (!file.medium || (format->tymed & *file.medium) == 0) return DV_E_TYMED;
    medium->tymed = *file.medium;
    if (*file.medium == TYMED_HGLOBAL) {
      // A block larger than the file, which the descriptor's size bounds.
      medium->hGlobal = Global(file.contents.data(), file.contents.size(), 16);
      return S_OK;
    }
    if (*file.medium == TYMED_ISTREAM) {
      const HRESULT hr = CreateStreamOnHGlobal(Global(file.contents.data(), file.contents.size(), 0), TRUE, &medium->pstm);
      // At its end, so the copy shows that the reader rewinds it.
      const LARGE_INTEGER end = {};
      if (SUCCEEDED(hr)) medium->pstm->Seek(end, STREAM_SEEK_END, nullptr);
      return hr;
    }
    ComPtr<IStorage> storage;
    HRESULT hr = StgCreateDocfile(nullptr, STGM_CREATE | STGM_READWRITE | STGM_SHARE_EXCLUSIVE | STGM_DELETEONRELEASE,
                                  0, &storage);
    ComPtr<IStream> body;
    if (SUCCEEDED(hr)) hr = storage->CreateStream(L"body", STGM_CREATE | STGM_WRITE | STGM_SHARE_EXCLUSIVE, 0, 0, &body);
    if (SUCCEEDED(hr)) hr = body->Write(file.contents.data(), static_cast<ULONG>(file.contents.size()), nullptr);
    if (FAILED(hr)) return hr;
    medium->pstg = storage.Detach();
    return S_OK;
  }

  HRESULT __stdcall GetDataHere(FORMATETC*, STGMEDIUM*) noexcept final { return E_NOTIMPL; }

  HRESULT __stdcall QueryGetData(FORMATETC* format) noexcept final {
    return format->cfFormat == descriptors_ || format->cfFormat == contents_ ? S_OK : DV_E_FORMATETC;
  }

  HRESULT __stdcall GetCanonicalFormatEtc(FORMATETC*, FORMATETC* out) noexcept final {
    out->ptd = nullptr;
    return E_NOTIMPL;
  }

  HRESULT __stdcall SetData(FORMATETC*, STGMEDIUM*, BOOL) noexcept final { return E_NOTIMPL; }
  HRESULT __stdcall EnumFormatEtc(DWORD, IEnumFORMATETC**) noexcept final { return E_NOTIMPL; }
  HRESULT __stdcall DAdvise(FORMATETC*, DWORD, IAdviseSink*, DWORD*) noexcept final {
    return OLE_E_ADVISENOTSUPPORTED;
  }
  HRESULT __stdcall DUnadvise(DWORD) noexcept final { return OLE_E_ADVISENOTSUPPORTED; }
  HRESULT __stdcall EnumDAdvise(IEnumSTATDATA**) noexcept final { return OLE_E_ADVISENOTSUPPORTED; }

 private:
  std::vector<Offered> files_;
  const CLIPFORMAT descriptors_ = static_cast<CLIPFORMAT>(RegisterClipboardFormatW(CFSTR_FILEDESCRIPTORW));
  const CLIPFORMAT contents_ = static_cast<CLIPFORMAT>(RegisterClipboardFormatW(CFSTR_FILECONTENTS));
};

std::string ReadCopy(const std::filesystem::path& path, bool storage) {
  if (!storage) {
    std::ifstream file(path, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>());
  }
  ComPtr<IStorage> copy;
  ComPtr<IStream> body;
  if (FAILED(StgOpenStorageEx(path.c_str(), STGM_READ | STGM_SHARE_EXCLUSIVE, STGFMT_STORAGE, 0, nullptr, nullptr,
                              IID_PPV_ARGS(&copy))) ||
      FAILED(copy->OpenStream(L"body", nullptr, STGM_READ | STGM_SHARE_EXCLUSIVE, 0, &body))) {
    return "";
  }
  std::string contents(64, '\0');
  ULONG read = 0;
  body->Read(contents.data(), static_cast<ULONG>(contents.size()), &read);
  contents.resize(read);
  return contents;
}

void CheckLogicalPoint() {
  // A popup window's client area starts at its position.
  const HWND view =
      CreateWindowExW(0, L"STATIC", L"", WS_POPUP, 100, 200, 400, 300, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  CHECK(view != nullptr);
  const ux::LogicalPoint at = ux::ToLogical(view, POINTL{100 + 300, 200 + 150}, 144);
  CHECK(at.x == 200 && at.y == 100);
  DestroyWindow(view);
}

void CheckVirtualFiles() {
  const winrt::com_ptr<VirtualFiles> data = winrt::make_self<VirtualFiles>(std::vector<Offered>{
      {L"photo.png", TYMED_ISTREAM, "a photo from a stream"},
      {L"photo.png", TYMED_HGLOBAL, "a photo from a block"},
      {L"album", std::nullopt, ""},
      {L"..\\..\\evil?.png", TYMED_ISTREAM, "a name that climbs"},
      {L"nul.txt", TYMED_ISTREAM, "a device's name"},
      {L"mail.msg", TYMED_ISTORAGE, "a message from a storage"},
  });
  CHECK(ux::OffersFiles(data.get()));
  const std::vector<std::pair<std::wstring, std::string>> expected = {
      {L"photo.png", "a photo from a stream"}, {L"photo.png", "a photo from a block"},
      {L"evil_.png", "a name that climbs"},    {L"_nul.txt", "a device's name"},
      {L"mail.msg", "a message from a storage"},
  };

  wchar_t temp[MAX_PATH + 1];
  CHECK(GetTempPathW(MAX_PATH + 1, temp) != 0);
  const std::filesystem::path drops = std::filesystem::path(temp) / L"ux_drops";
  const std::vector<ux::DroppedFile> copies = ux::WriteVirtualFiles(data.get());
  CHECK(copies.size() == expected.size());
  std::set<std::filesystem::path> dirs;
  for (size_t i = 0; i < copies.size() && i < expected.size(); i++) {
    const std::filesystem::path path(copies[i].path);
    const std::filesystem::path dir = path.parent_path();
    CHECK(copies[i].name == expected[i].first);
    CHECK(copies[i].is_temporary_copy && !copies[i].is_directory);
    CHECK(path.filename() == expected[i].first);
    CHECK(dir.parent_path() == drops);
    CHECK(dir.filename().wstring().size() == 36);
    CHECK(std::distance(std::filesystem::directory_iterator(dir), std::filesystem::directory_iterator()) == 1);
    CHECK(ReadCopy(path, expected[i].first == L"mail.msg") == expected[i].second);
    dirs.insert(dir);
  }
  CHECK(dirs.size() == copies.size());
  for (const std::filesystem::path& dir : dirs) {
    std::error_code error;
    std::filesystem::remove_all(dir, error);
  }
}

}  // namespace

void DropSuite() {
  CHECK(SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED)));
  CheckLogicalPoint();
  CheckVirtualFiles();
  CoUninitialize();
}
