#ifndef UX_VIDEO_READER_H_
#define UX_VIDEO_READER_H_

#include <windows.h>

#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "raster.h"

namespace ux {

// 16-bit PCM, interleaved.
struct AudioFormat {
  UINT rate;
  UINT channels;
};

// What VideoReader::Read decoded.
struct Decoded {
  enum class Kind { kFrame, kAudio, kVideoEnd, kAudioEnd };

  Kind kind = Kind::kFrame;
  // The presentation time and duration of a frame or of audio, in 100 ns.
  LONGLONG time = 0;
  std::optional<LONGLONG> duration;
  // A frame, opaque, in its stored orientation.
  Image frame;
  // Audio in the reader's AudioFormat.
  std::vector<uint8_t> pcm;
};

// A file's first video track, decoded to BGRA by an IMFSourceReader, and,
// when asked for, its first audio track decoded to 16-bit PCM. It runs on a
// thread where a MediaWork has started.
class VideoReader {
 public:
  // Sets [reader] to a reader of the file at [path], with its audio when
  // [audio] holds. Fails with MF_E_INVALIDSTREAMNUMBER when the file has no
  // video track. Audio that Windows cannot decode is left out.
  static HRESULT Open(const std::wstring& path, bool audio, std::unique_ptr<VideoReader>& reader);

  VideoReader(const VideoReader&) = delete;
  VideoReader& operator=(const VideoReader&) = delete;

  // The frames' stored size.
  UINT width() const { return width_; }
  UINT height() const { return height_; }
  // The quarter turns clockwise that bring a stored frame upright.
  int turns() const { return turns_; }
  // In 100 ns; none when the file states none.
  std::optional<LONGLONG> duration() const { return duration_; }
  // In frames per second; none when the track states none.
  std::optional<double> frame_rate() const { return frame_rate_; }
  // In bits per second; none when the track states none.
  std::optional<UINT> bitrate() const { return bitrate_; }
  // None when the reader reads no audio.
  std::optional<AudioFormat> audio() const { return audio_; }

  // Reads from the key frame at or before [time], in 100 ns.
  HRESULT Seek(LONGLONG time);

  // Decodes the next frame, piece of audio or end of a track into [decoded],
  // reusing its buffers.
  HRESULT Read(Decoded& decoded);

  // Decodes into [frame] the frame nearest [time], in 100 ns, when one lies
  // within [tolerance] of it.
  HRESULT FrameAt(LONGLONG time, LONGLONG tolerance, std::optional<Decoded>& frame);

 private:
  VideoReader() = default;

  HRESULT ConfigureVideo();
  HRESULT ConfigureAudio();
  HRESULT ReadFormat();
  HRESULT CopyFrame(IMFSample* sample, Image& frame) const;

  Microsoft::WRL::ComPtr<IMFSourceReader> reader_;
  DWORD video_stream_ = 0;
  std::optional<DWORD> audio_stream_;
  UINT width_ = 0;
  UINT height_ = 0;
  // Where the visible frame lies in a decoded buffer of rows_ rows, each
  // stride_ bytes from the one above.
  UINT left_ = 0;
  UINT top_ = 0;
  UINT32 rows_ = 0;
  LONG stride_ = 0;
  int turns_ = 0;
  std::optional<LONGLONG> duration_;
  std::optional<double> frame_rate_;
  std::optional<UINT> bitrate_;
  std::optional<AudioFormat> audio_;
};

}  // namespace ux

#endif  // UX_VIDEO_READER_H_
