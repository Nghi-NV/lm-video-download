import 'dart:typed_data';
import 'codecs.dart';

/// Một frame AAC thô (đã bỏ ADTS header).
class AacFrame {
  final Uint8List data;
  AacFrame(this.data);
}

/// Kết quả parse các PES payload audio (ADTS) thành các frame AAC.
class AacParseResult {
  final AudioConfig config;
  final List<AacFrame> frames;
  AacParseResult(this.config, this.frames);
}

/// Tách các frame ADTS từ chuỗi payload audio đã nối. Trả về cấu hình AAC
/// (lấy từ frame đầu) và danh sách frame thô. Trả về null nếu không nhận dạng
/// được ADTS hợp lệ.
AacParseResult? parseAdts(Uint8List data) {
  final frames = <AacFrame>[];
  AudioConfig? config;

  var i = 0;
  final n = data.length;
  while (i + 7 <= n) {
    // syncword 0xFFF
    if (data[i] != 0xFF || (data[i + 1] & 0xF0) != 0xF0) {
      i++;
      continue;
    }
    final protectionAbsent = data[i + 1] & 0x01;
    final profile = (data[i + 2] >> 6) & 0x03; // object type - 1
    final freqIndex = (data[i + 2] >> 2) & 0x0F;
    final channelConfig =
        ((data[i + 2] & 0x01) << 2) | ((data[i + 3] >> 6) & 0x03);
    final frameLength = ((data[i + 3] & 0x03) << 11) |
        (data[i + 4] << 3) |
        ((data[i + 5] >> 5) & 0x07);

    if (frameLength < 7 || i + frameLength > n) {
      break;
    }

    final headerLen = protectionAbsent == 1 ? 7 : 9;
    if (frameLength > headerLen) {
      frames.add(AacFrame(
          Uint8List.sublistView(data, i + headerLen, i + frameLength)));
      config ??= AudioConfig(
        sampleRate: freqIndex < aacSampleRates.length
            ? aacSampleRates[freqIndex]
            : 0,
        channelCount: channelConfig,
        objectType: profile + 1,
        samplingFrequencyIndex: freqIndex,
      );
    }
    i += frameLength;
  }

  if (config == null || frames.isEmpty || config.sampleRate == 0) {
    return null;
  }
  return AacParseResult(config, frames);
}
