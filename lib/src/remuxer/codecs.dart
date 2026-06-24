import 'dart:typed_data';
import 'bit_reader.dart';

/// Loại codec video được hỗ trợ.
enum VideoCodec { h264, h265 }

/// Thông tin cấu hình của track video (sau khi parse SPS/PPS/VPS).
class VideoConfig {
  final VideoCodec codec;
  final int width;
  final int height;

  /// Box cấu hình giải mã (avcC cho H.264, hvcC cho H.265) đã build sẵn,
  /// dùng làm phần đuôi của VisualSampleEntry trong moov.
  final Uint8List configBox;

  VideoConfig({
    required this.codec,
    required this.width,
    required this.height,
    required this.configBox,
  });
}

/// Thông tin cấu hình track audio AAC.
class AudioConfig {
  final int sampleRate;
  final int channelCount;
  final int objectType; // AAC object type (vd: 2 = AAC LC)
  final int samplingFrequencyIndex;

  AudioConfig({
    required this.sampleRate,
    required this.channelCount,
    required this.objectType,
    required this.samplingFrequencyIndex,
  });

  /// AudioSpecificConfig (2 byte cho cấu hình thường gặp).
  Uint8List buildAudioSpecificConfig() {
    // 5 bit objectType, 4 bit freqIndex, 4 bit channelConfig, 3 bit padding
    final b0 = (objectType << 3) | ((samplingFrequencyIndex >> 1) & 0x07);
    final b1 = ((samplingFrequencyIndex & 0x01) << 7) | ((channelCount & 0x0F) << 3);
    return Uint8List.fromList([b0, b1]);
  }
}

const List<int> aacSampleRates = [
  96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
  16000, 12000, 11025, 8000, 7350, 0, 0, 0,
];

/// Phân tích H.264 SPS (NAL đã bỏ start code, còn nguyên header byte) để lấy
/// width/height.
class _H264Sps {
  final int width;
  final int height;
  _H264Sps(this.width, this.height);
}

_H264Sps _parseH264Sps(Uint8List nalWithHeader) {
  // Bỏ 1 byte NAL header, chuyển EBSP -> RBSP
  final rbsp = BitReader.ebspToRbsp(
      Uint8List.sublistView(nalWithHeader, 1, nalWithHeader.length));
  final r = BitReader(rbsp);

  final profileIdc = r.readBits(8);
  r.skipBits(8); // constraint flags + reserved
  r.readBits(8); // level_idc
  r.readUE(); // seq_parameter_set_id

  var chromaFormatIdc = 1;
  if ([100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]
      .contains(profileIdc)) {
    chromaFormatIdc = r.readUE();
    if (chromaFormatIdc == 3) r.skipBits(1); // separate_colour_plane_flag
    r.readUE(); // bit_depth_luma_minus8
    r.readUE(); // bit_depth_chroma_minus8
    r.skipBits(1); // qpprime_y_zero_transform_bypass_flag
    final scalingMatrixPresent = r.readBit();
    if (scalingMatrixPresent == 1) {
      final count = chromaFormatIdc != 3 ? 8 : 12;
      for (var i = 0; i < count; i++) {
        final present = r.readBit();
        if (present == 1) {
          final size = i < 6 ? 16 : 64;
          var lastScale = 8;
          var nextScale = 8;
          for (var j = 0; j < size; j++) {
            if (nextScale != 0) {
              final delta = r.readSE();
              nextScale = (lastScale + delta + 256) % 256;
            }
            lastScale = nextScale == 0 ? lastScale : nextScale;
          }
        }
      }
    }
  }

  r.readUE(); // log2_max_frame_num_minus4
  final picOrderCntType = r.readUE();
  if (picOrderCntType == 0) {
    r.readUE(); // log2_max_pic_order_cnt_lsb_minus4
  } else if (picOrderCntType == 1) {
    r.skipBits(1); // delta_pic_order_always_zero_flag
    r.readSE(); // offset_for_non_ref_pic
    r.readSE(); // offset_for_top_to_bottom_field
    final numRefFrames = r.readUE();
    for (var i = 0; i < numRefFrames; i++) {
      r.readSE();
    }
  }
  r.readUE(); // max_num_ref_frames
  r.skipBits(1); // gaps_in_frame_num_value_allowed_flag

  final picWidthInMbsMinus1 = r.readUE();
  final picHeightInMapUnitsMinus1 = r.readUE();
  final frameMbsOnlyFlag = r.readBit();
  if (frameMbsOnlyFlag == 0) {
    r.skipBits(1); // mb_adaptive_frame_field_flag
  }
  r.skipBits(1); // direct_8x8_inference_flag

  var cropLeft = 0, cropRight = 0, cropTop = 0, cropBottom = 0;
  final frameCroppingFlag = r.readBit();
  if (frameCroppingFlag == 1) {
    cropLeft = r.readUE();
    cropRight = r.readUE();
    cropTop = r.readUE();
    cropBottom = r.readUE();
  }

  final subWidthC = chromaFormatIdc == 1 || chromaFormatIdc == 2 ? 2 : 1;
  final subHeightC = chromaFormatIdc == 1 ? 2 : 1;
  final cropUnitX = chromaFormatIdc == 0 ? 1 : subWidthC;
  final cropUnitY =
      (chromaFormatIdc == 0 ? 1 : subHeightC) * (2 - frameMbsOnlyFlag);

  final width = (picWidthInMbsMinus1 + 1) * 16 - cropUnitX * (cropLeft + cropRight);
  final height = (2 - frameMbsOnlyFlag) * (picHeightInMapUnitsMinus1 + 1) * 16 -
      cropUnitY * (cropTop + cropBottom);

  return _H264Sps(width, height);
}

/// Build avcC (AVCDecoderConfigurationRecord) từ SPS + PPS (NAL còn header byte).
Uint8List _buildAvcC(Uint8List sps, Uint8List pps) {
  final b = BytesBuilder();
  b.addByte(1); // configurationVersion
  b.addByte(sps[1]); // AVCProfileIndication
  b.addByte(sps[2]); // profile_compatibility
  b.addByte(sps[3]); // AVCLevelIndication
  b.addByte(0xFF); // 6 bit reserved + lengthSizeMinusOne(3)
  b.addByte(0xE1); // 3 bit reserved + numOfSPS(1)
  b.addByte((sps.length >> 8) & 0xFF);
  b.addByte(sps.length & 0xFF);
  b.add(sps);
  b.addByte(1); // numOfPPS
  b.addByte((pps.length >> 8) & 0xFF);
  b.addByte(pps.length & 0xFF);
  b.add(pps);
  return b.toBytes();
}

VideoConfig buildH264Config(Uint8List sps, Uint8List pps) {
  final parsed = _parseH264Sps(sps);
  return VideoConfig(
    codec: VideoCodec.h264,
    width: parsed.width,
    height: parsed.height,
    configBox: _buildAvcC(sps, pps),
  );
}

// ---------------- HEVC / H.265 ----------------

class _H265Sps {
  final int width;
  final int height;
  final int chromaFormatIdc;
  final int bitDepthLumaMinus8;
  final int bitDepthChromaMinus8;
  final Uint8List generalPtl; // 12 byte
  _H265Sps(this.width, this.height, this.chromaFormatIdc,
      this.bitDepthLumaMinus8, this.bitDepthChromaMinus8, this.generalPtl);
}

_H265Sps _parseH265Sps(Uint8List nalWithHeader) {
  // HEVC NAL header = 2 byte
  final rbsp = BitReader.ebspToRbsp(
      Uint8List.sublistView(nalWithHeader, 2, nalWithHeader.length));
  final r = BitReader(rbsp);

  r.readBits(4); // sps_video_parameter_set_id
  final maxSubLayersMinus1 = r.readBits(3);
  r.skipBits(1); // sps_temporal_id_nesting_flag

  // general profile_tier_level = 12 byte, byte-aligned tại rbsp[1..13)
  final generalPtl = Uint8List.sublistView(rbsp, 1, 13);
  r.skipBits(96); // consume 12 byte general PTL

  // sub-layer present flags
  final subLayerProfilePresent = <int>[];
  final subLayerLevelPresent = <int>[];
  for (var i = 0; i < maxSubLayersMinus1; i++) {
    subLayerProfilePresent.add(r.readBit());
    subLayerLevelPresent.add(r.readBit());
  }
  if (maxSubLayersMinus1 > 0) {
    for (var i = maxSubLayersMinus1; i < 8; i++) {
      r.skipBits(2); // reserved_zero_2bits
    }
  }
  for (var i = 0; i < maxSubLayersMinus1; i++) {
    if (subLayerProfilePresent[i] == 1) r.skipBits(88);
    if (subLayerLevelPresent[i] == 1) r.skipBits(8);
  }

  r.readUE(); // sps_seq_parameter_set_id
  final chromaFormatIdc = r.readUE();
  if (chromaFormatIdc == 3) r.skipBits(1); // separate_colour_plane_flag

  final picWidth = r.readUE();
  final picHeight = r.readUE();

  var confLeft = 0, confRight = 0, confTop = 0, confBottom = 0;
  final conformanceWindowFlag = r.readBit();
  if (conformanceWindowFlag == 1) {
    confLeft = r.readUE();
    confRight = r.readUE();
    confTop = r.readUE();
    confBottom = r.readUE();
  }

  final bitDepthLumaMinus8 = r.readUE();
  final bitDepthChromaMinus8 = r.readUE();

  final subWidthC = chromaFormatIdc == 1 || chromaFormatIdc == 2 ? 2 : 1;
  final subHeightC = chromaFormatIdc == 1 ? 2 : 1;
  final width = picWidth - subWidthC * (confLeft + confRight);
  final height = picHeight - subHeightC * (confTop + confBottom);

  return _H265Sps(width, height, chromaFormatIdc, bitDepthLumaMinus8,
      bitDepthChromaMinus8, generalPtl);
}

/// Build hvcC (HEVCDecoderConfigurationRecord) chứa VPS/SPS/PPS.
Uint8List _buildHvcC(Uint8List vps, Uint8List sps, Uint8List pps, _H265Sps p) {
  final b = BytesBuilder();
  b.addByte(1); // configurationVersion
  // general PTL: 12 byte (profile_space/tier/idc + 32 bit compat + 48 bit
  // constraint + level_idc)
  b.add(p.generalPtl);
  // min_spatial_segmentation_idc (12 bit) với 4 bit reserved 1111
  b.addByte(0xF0);
  b.addByte(0x00);
  b.addByte(0xFC); // 6 bit reserved + parallelismType(2)=0
  b.addByte(0xFC | (p.chromaFormatIdc & 0x03));
  b.addByte(0xF8 | (p.bitDepthLumaMinus8 & 0x07));
  b.addByte(0xF8 | (p.bitDepthChromaMinus8 & 0x07));
  b.addByte(0x00); // avgFrameRate hi
  b.addByte(0x00); // avgFrameRate lo
  // constantFrameRate(2)=0 numTemporalLayers(3)=1 temporalIdNested(1)=0
  // lengthSizeMinusOne(2)=3
  b.addByte(0x0B);
  b.addByte(3); // numOfArrays: VPS, SPS, PPS

  void addArray(int nalType, Uint8List nal) {
    b.addByte(0x80 | (nalType & 0x3F)); // array_completeness=1
    b.addByte(0x00);
    b.addByte(0x01); // numNalus = 1
    b.addByte((nal.length >> 8) & 0xFF);
    b.addByte(nal.length & 0xFF);
    b.add(nal);
  }

  addArray(32, vps); // VPS
  addArray(33, sps); // SPS
  addArray(34, pps); // PPS
  return b.toBytes();
}

VideoConfig buildH265Config(Uint8List vps, Uint8List sps, Uint8List pps) {
  final parsed = _parseH265Sps(sps);
  return VideoConfig(
    codec: VideoCodec.h265,
    width: parsed.width,
    height: parsed.height,
    configBox: _buildHvcC(vps, sps, pps, parsed),
  );
}
