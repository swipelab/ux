/*
 * Copyright 2026 swipelab.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * JNI bridge for the ux FFmpeg video decoder. Exposes a small surface
 * (init / sendPacket / receiveFrame / flush / release) that
 * FfmpegVideoDecoder.java drives. The audio path was dropped — Media3's
 * MediaCodec AAC decoder handles audio on every device we ship to.
 */
#include <android/log.h>
#include <jni.h>
#include <stdlib.h>
#include <string.h>

extern "C" {
#ifdef __cplusplus
#define __STDC_CONSTANT_MACROS
#ifdef _STDINT_H
#undef _STDINT_H
#endif
#include <stdint.h>
#endif
#include <libavcodec/avcodec.h>
#include <libavutil/error.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/pixfmt.h>
}

#define LOG_TAG "ux_ffmpeg_jni"
#define LOGE(...) \
  ((void)__android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__))
#define LOGI(...) \
  ((void)__android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__))
#define LOGD(...) \
  ((void)__android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__))

#define LIBRARY_FUNC(RETURN_TYPE, NAME, ...)                                  \
  extern "C" {                                                                \
  JNIEXPORT RETURN_TYPE                                                       \
  Java_io_swipelab_ux_video_ffmpeg_FfmpegLibrary_##NAME(JNIEnv* env,          \
                                                        jobject thiz,         \
                                                        ##__VA_ARGS__);       \
  }                                                                           \
  JNIEXPORT RETURN_TYPE                                                       \
  Java_io_swipelab_ux_video_ffmpeg_FfmpegLibrary_##NAME(                      \
      JNIEnv* env, jobject thiz, ##__VA_ARGS__)

#define VIDEO_DECODER_FUNC(RETURN_TYPE, NAME, ...)                            \
  extern "C" {                                                                \
  JNIEXPORT RETURN_TYPE                                                       \
  Java_io_swipelab_ux_video_ffmpeg_FfmpegVideoDecoder_##NAME(                 \
      JNIEnv* env, jobject thiz, ##__VA_ARGS__);                              \
  }                                                                           \
  JNIEXPORT RETURN_TYPE                                                       \
  Java_io_swipelab_ux_video_ffmpeg_FfmpegVideoDecoder_##NAME(                 \
      JNIEnv* env, jobject thiz, ##__VA_ARGS__)

#define ERROR_STRING_BUFFER_LENGTH 256

// Mirrored in FfmpegVideoDecoder.java.
static const int VIDEO_DECODER_SUCCESS = 0;
static const int VIDEO_DECODER_ERROR_INVALID_DATA = -1;
static const int VIDEO_DECODER_ERROR_OTHER = -2;
static const int VIDEO_DECODER_READ_AGAIN = -3;

// VideoDecoderOutputBuffer.COLORSPACE_* mirror.
static const int COLORSPACE_UNKNOWN = 0;
static const int COLORSPACE_BT601 = 1;
static const int COLORSPACE_BT709 = 2;
static const int COLORSPACE_BT2020 = 3;

static jmethodID initForYuvFrameMethod;
static jfieldID dataField;
// Carries full-range info (1) vs limited-range info (0) per frame to
// Java so the GL shader picks the matching BT.709 conversion matrix.
static jfieldID decoderPrivateField;
// Reassigned per output frame to the decoded frame's actual PTS
// (NOT the input packet's PTS — for H.264 reorder, output display
// order differs from input decode order, and using the input PTS
// scrambles ExoPlayer's frame-late detection so it drops half the
// stream).
static jfieldID timeUsField;

static int colorspaceFromAVColorSpace(AVColorSpace cs) {
  switch (cs) {
    case AVCOL_SPC_BT709:
      return COLORSPACE_BT709;
    case AVCOL_SPC_BT470BG:
    case AVCOL_SPC_SMPTE170M:
      return COLORSPACE_BT601;
    case AVCOL_SPC_BT2020_NCL:
    case AVCOL_SPC_BT2020_CL:
      return COLORSPACE_BT2020;
    default:
      return COLORSPACE_UNKNOWN;
  }
}

static void logError(const char* fn, int err) {
  char buf[ERROR_STRING_BUFFER_LENGTH] = {0};
  av_strerror(err, buf, ERROR_STRING_BUFFER_LENGTH);
  LOGE("Error in %s: %s", fn, buf);
}

static int transformError(int err) {
  return err == AVERROR_INVALIDDATA ? VIDEO_DECODER_ERROR_INVALID_DATA
                                    : VIDEO_DECODER_ERROR_OTHER;
}

// Decoder state held across JNI calls; the long handle returned by
// videoInitialize is a pointer to one of these. AVCodecContext alone
// isn't enough because we want a reusable AVFrame to avoid per-decode
// allocation churn.
struct UxFfmpegVideoContext {
  AVCodecContext* codec_ctx = nullptr;
  AVFrame* frame = nullptr;
};

static void releaseContext(UxFfmpegVideoContext* ctx) {
  if (!ctx) return;
  if (ctx->frame) {
    av_frame_free(&ctx->frame);
  }
  if (ctx->codec_ctx) {
    avcodec_free_context(&ctx->codec_ctx);
  }
  delete ctx;
}

jint JNI_OnLoad(JavaVM* vm, void* reserved) {
  JNIEnv* env;
  if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
    LOGE("JNI_OnLoad: GetEnv failed");
    return -1;
  }
  jclass clazz =
      env->FindClass("androidx/media3/decoder/VideoDecoderOutputBuffer");
  if (!clazz) {
    LOGE("JNI_OnLoad: FindClass(VideoDecoderOutputBuffer) failed");
    return -1;
  }
  initForYuvFrameMethod = env->GetMethodID(clazz, "initForYuvFrame", "(IIIII)Z");
  if (!initForYuvFrameMethod) {
    LOGE("JNI_OnLoad: GetMethodID(initForYuvFrame) failed");
    return -1;
  }
  dataField = env->GetFieldID(clazz, "data", "Ljava/nio/ByteBuffer;");
  if (!dataField) {
    LOGE("JNI_OnLoad: GetFieldID(data) failed");
    return -1;
  }
  decoderPrivateField = env->GetFieldID(clazz, "decoderPrivate", "J");
  if (!decoderPrivateField) {
    LOGE("JNI_OnLoad: GetFieldID(decoderPrivate) failed");
    return -1;
  }
  // timeUs lives on the DecoderOutputBuffer base class but is
  // discoverable via the concrete subclass.
  timeUsField = env->GetFieldID(clazz, "timeUs", "J");
  if (!timeUsField) {
    LOGE("JNI_OnLoad: GetFieldID(timeUs) failed");
    return -1;
  }
  return JNI_VERSION_1_6;
}

LIBRARY_FUNC(jstring, ffmpegGetVersion) {
  return env->NewStringUTF(LIBAVCODEC_IDENT);
}

LIBRARY_FUNC(jint, ffmpegGetInputBufferPaddingSize) {
  return (jint)AV_INPUT_BUFFER_PADDING_SIZE;
}

LIBRARY_FUNC(jboolean, ffmpegHasDecoder, jstring codecName) {
  if (!codecName) return JNI_FALSE;
  const char* name = env->GetStringUTFChars(codecName, nullptr);
  const AVCodec* codec = avcodec_find_decoder_by_name(name);
  env->ReleaseStringUTFChars(codecName, name);
  return codec != nullptr;
}

VIDEO_DECODER_FUNC(jlong, ffmpegVideoInitialize, jstring codecName,
                   jbyteArray extraData, jint threads) {
  if (!codecName) {
    LOGE("ffmpegVideoInitialize: codecName is null");
    return 0L;
  }
  const char* name = env->GetStringUTFChars(codecName, nullptr);
  const AVCodec* codec = avcodec_find_decoder_by_name(name);
  env->ReleaseStringUTFChars(codecName, name);
  if (!codec) {
    LOGE("ffmpegVideoInitialize: codec not found");
    return 0L;
  }

  UxFfmpegVideoContext* ctx = new UxFfmpegVideoContext();
  ctx->codec_ctx = avcodec_alloc_context3(codec);
  if (!ctx->codec_ctx) {
    LOGE("ffmpegVideoInitialize: avcodec_alloc_context3 failed");
    releaseContext(ctx);
    return 0L;
  }

  if (extraData) {
    jsize size = env->GetArrayLength(extraData);
    ctx->codec_ctx->extradata =
        (uint8_t*)av_mallocz(size + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!ctx->codec_ctx->extradata) {
      LOGE("ffmpegVideoInitialize: extradata alloc failed");
      releaseContext(ctx);
      return 0L;
    }
    env->GetByteArrayRegion(extraData, 0, size,
                            (jbyte*)ctx->codec_ctx->extradata);
    ctx->codec_ctx->extradata_size = size;
  }

  ctx->codec_ctx->thread_count = threads > 0 ? threads : 0;
  // Slice threading only. FRAME threading buffers thread_count
  // input frames before producing output; that extra latency
  // pushes frames past their PTS deadline and ExoPlayer drops
  // them, leaving render rate well below source rate. Slice
  // threading gives parallelism without the input-side delay.
  ctx->codec_ctx->thread_type = FF_THREAD_SLICE;
  ctx->codec_ctx->err_recognition = AV_EF_IGNORE_ERR;
  // PTS values are passed in microseconds (Media3's native unit),
  // and libavcodec propagates packet.pts → frame.pts through the
  // reorder buffer so we can recover display-order timestamps on
  // receive.
  ctx->codec_ctx->time_base = AVRational{1, 1000000};
  ctx->codec_ctx->pkt_timebase = AVRational{1, 1000000};

  int result = avcodec_open2(ctx->codec_ctx, codec, nullptr);
  if (result < 0) {
    logError("avcodec_open2", result);
    releaseContext(ctx);
    return 0L;
  }

  ctx->frame = av_frame_alloc();
  if (!ctx->frame) {
    LOGE("ffmpegVideoInitialize: av_frame_alloc failed");
    releaseContext(ctx);
    return 0L;
  }
  return (jlong)ctx;
}

VIDEO_DECODER_FUNC(jint, ffmpegVideoSendPacket, jlong handle, jobject inputData,
                   jint inputSize, jlong ptsUs) {
  if (!handle) {
    LOGE("ffmpegVideoSendPacket: null handle");
    return VIDEO_DECODER_ERROR_OTHER;
  }
  if (!inputData || inputSize <= 0) {
    LOGE("ffmpegVideoSendPacket: bad input");
    return VIDEO_DECODER_ERROR_OTHER;
  }
  UxFfmpegVideoContext* ctx = (UxFfmpegVideoContext*)handle;
  uint8_t* buf = (uint8_t*)env->GetDirectBufferAddress(inputData);
  AVPacket* pkt = av_packet_alloc();
  if (!pkt) {
    LOGE("ffmpegVideoSendPacket: av_packet_alloc failed");
    return VIDEO_DECODER_ERROR_OTHER;
  }
  pkt->data = buf;
  pkt->size = inputSize;
  pkt->pts = (int64_t)ptsUs;
  pkt->dts = AV_NOPTS_VALUE;
  int result = avcodec_send_packet(ctx->codec_ctx, pkt);
  av_packet_free(&pkt);
  if (result == AVERROR(EAGAIN)) {
    return VIDEO_DECODER_READ_AGAIN;
  }
  if (result < 0) {
    logError("avcodec_send_packet", result);
    return transformError(result);
  }
  return VIDEO_DECODER_SUCCESS;
}

// Pulls the next decoded frame and writes it into the Java
// VideoDecoderOutputBuffer's YUV planes. Returns:
//   VIDEO_DECODER_SUCCESS       -> frame written
//   VIDEO_DECODER_READ_AGAIN    -> no frame yet, send more packets
//   VIDEO_DECODER_ERROR_*       -> fatal
VIDEO_DECODER_FUNC(jint, ffmpegVideoReceiveFrame, jlong handle,
                   jobject outputBuffer) {
  if (!handle) {
    LOGE("ffmpegVideoReceiveFrame: null handle");
    return VIDEO_DECODER_ERROR_OTHER;
  }
  UxFfmpegVideoContext* ctx = (UxFfmpegVideoContext*)handle;
  int result = avcodec_receive_frame(ctx->codec_ctx, ctx->frame);
  if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) {
    return VIDEO_DECODER_READ_AGAIN;
  }
  if (result < 0) {
    logError("avcodec_receive_frame", result);
    return transformError(result);
  }

  AVFrame* f = ctx->frame;
  // Only planar 4:2:0 YUV is supported by VideoDecoderOutputBuffer's
  // 3-plane layout. iOS H.264 produces YUV420P (limited range) or
  // YUVJ420P (full range); identical memory layout, only range
  // interpretation differs.
  AVPixelFormat pix = (AVPixelFormat)f->format;
  if (pix != AV_PIX_FMT_YUV420P && pix != AV_PIX_FMT_YUVJ420P) {
    LOGE("ffmpegVideoReceiveFrame: unsupported pix_fmt=%d", pix);
    av_frame_unref(f);
    return VIDEO_DECODER_ERROR_OTHER;
  }

  int width = f->width;
  int height = f->height;
  int yStride = f->linesize[0];
  int uvStride = f->linesize[1];
  int colorspace = colorspaceFromAVColorSpace(f->colorspace);
  if (colorspace == COLORSPACE_UNKNOWN) {
    // iOS H.264 commonly leaves VUI fields unspecified; default to
    // BT.709 for HD-shaped frames, BT.601 below SD width threshold.
    colorspace = (width >= 1280 || height >= 720) ? COLORSPACE_BT709
                                                  : COLORSPACE_BT601;
  }

  jboolean ok = env->CallBooleanMethod(outputBuffer, initForYuvFrameMethod,
                                       width, height, yStride, uvStride,
                                       colorspace);
  if (env->ExceptionCheck()) {
    LOGE("initForYuvFrame threw");
    env->ExceptionDescribe();
    env->ExceptionClear();
    av_frame_unref(f);
    return VIDEO_DECODER_ERROR_OTHER;
  }
  if (!ok) {
    LOGE("initForYuvFrame returned false (overflow?)");
    av_frame_unref(f);
    return VIDEO_DECODER_ERROR_OTHER;
  }

  // Display-order PTS recovered from libavcodec. The Java side
  // initialised the buffer with the input packet's PTS; for B-frame
  // streams that is the WRONG value because the frame we're about to
  // emit was decoded out of input order. Overwriting with f->pts puts
  // each output buffer back on the timeline ExoPlayer expects.
  if (f->pts != AV_NOPTS_VALUE) {
    env->SetLongField(outputBuffer, timeUsField, (jlong)f->pts);
  }

  // Copy each plane into the ByteBuffer that initForYuvFrame allocated.
  jobject dataBuf = env->GetObjectField(outputBuffer, dataField);
  if (!dataBuf) {
    LOGE("ffmpegVideoReceiveFrame: data ByteBuffer is null after init");
    av_frame_unref(f);
    return VIDEO_DECODER_ERROR_OTHER;
  }
  uint8_t* dst = (uint8_t*)env->GetDirectBufferAddress(dataBuf);
  if (!dst) {
    LOGE("ffmpegVideoReceiveFrame: GetDirectBufferAddress null");
    env->DeleteLocalRef(dataBuf);
    av_frame_unref(f);
    return VIDEO_DECODER_ERROR_OTHER;
  }

  int uvHeight = (height + 1) / 2;
  int yLength = yStride * height;
  int uvLength = uvStride * uvHeight;

  // Plane 0: Y
  memcpy(dst, f->data[0], yLength);
  // Plane 1: U
  memcpy(dst + yLength, f->data[1], uvLength);
  // Plane 2: V
  memcpy(dst + yLength + uvLength, f->data[2], uvLength);

  // iOS yuvj420p / AVCOL_RANGE_JPEG => full-range YUV; the renderer's
  // shader needs to skip the limited-range pre-scale on Y.
  jlong rangeFlag = (pix == AV_PIX_FMT_YUVJ420P ||
                     f->color_range == AVCOL_RANGE_JPEG)
                        ? 1L
                        : 0L;
  env->SetLongField(outputBuffer, decoderPrivateField, rangeFlag);

  env->DeleteLocalRef(dataBuf);
  av_frame_unref(f);
  return VIDEO_DECODER_SUCCESS;
}

VIDEO_DECODER_FUNC(void, ffmpegVideoFlush, jlong handle) {
  if (!handle) return;
  UxFfmpegVideoContext* ctx = (UxFfmpegVideoContext*)handle;
  avcodec_flush_buffers(ctx->codec_ctx);
}

VIDEO_DECODER_FUNC(void, ffmpegVideoRelease, jlong handle) {
  if (!handle) return;
  releaseContext((UxFfmpegVideoContext*)handle);
}
