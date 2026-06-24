import 'dart:typed_data';
import 'aac.dart';
import 'codecs.dart';
import 'mp4_muxer.dart';
import 'nal.dart';
import 'ts_demuxer.dart';

/// Ngoại lệ phát sinh khi remux thất bại.
class RemuxException implements Exception {
  final String message;
  RemuxException(this.message);
  @override
  String toString() => 'RemuxException: $message';
}

const int _videoTimescale = 90000; // đơn vị PTS/DTS của MPEG-TS
const int _ptsWrap = 0x200000000; // 2^33
const int _defaultFrameDuration = 3000; // ~30fps @ 90kHz (fallback)

/// Bỏ wrap-around 33-bit của PTS/DTS để có chuỗi tăng đơn điệu.
List<int> _unwrap(List<int?> values, int fallbackStart) {
  final out = <int>[];
  var offset = 0;
  int? last;
  for (final v in values) {
    var cur = v ?? (last == null ? fallbackStart : last + _defaultFrameDuration);
    if (last != null && cur + offset < last - 0x100000000) {
      offset += _ptsWrap;
    }
    final unwrapped = cur + offset;
    out.add(unwrapped);
    last = unwrapped;
  }
  return out;
}

/// Remux một buffer MPEG-TS (đã ghép từ các segment .ts) sang MP4.
///
/// Trả về bytes MP4. Ném [RemuxException] nếu không tìm thấy video hợp lệ.
Uint8List remuxTsToMp4(Uint8List ts) {
  final demux = demuxTs(ts);
  if (demux.videoStreamType == null || demux.videoUnits.isEmpty) {
    throw RemuxException('Không tìm thấy track video trong MPEG-TS');
  }

  final isH265 = demux.videoStreamType == 0x24;

  // 1. Quét các unit video: trích param set (VPS/SPS/PPS) + tạo sample.
  Uint8List? vps, sps, pps;
  final videoSamplesBytes = <Uint8List>[];
  final videoIsSync = <bool>[];
  final videoPts = <int?>[];
  final videoDts = <int?>[];

  for (final unit in demux.videoUnits) {
    final nals = splitAnnexB(unit.data);
    final keep = <Uint8List>[];
    var isSync = false;

    for (final nal in nals) {
      if (nal.isEmpty) continue;
      if (isH265) {
        final type = (nal[0] >> 1) & 0x3F;
        switch (type) {
          case 32:
            vps ??= nal;
            break;
          case 33:
            sps ??= nal;
            break;
          case 34:
            pps ??= nal;
            break;
          case 35: // AUD
            break;
          default:
            if (type >= 16 && type <= 23) isSync = true;
            keep.add(nal);
        }
      } else {
        final type = nal[0] & 0x1F;
        switch (type) {
          case 7:
            sps ??= nal;
            break;
          case 8:
            pps ??= nal;
            break;
          case 9: // AUD
            break;
          default:
            if (type == 5) isSync = true;
            keep.add(nal);
        }
      }
    }

    if (keep.isEmpty) continue;
    videoSamplesBytes.add(toLengthPrefixed(keep));
    videoIsSync.add(isSync);
    videoPts.add(unit.pts);
    videoDts.add(unit.dts ?? unit.pts);
  }

  if (sps == null || pps == null) {
    throw RemuxException('Thiếu SPS/PPS trong stream video');
  }
  if (isH265 && vps == null) {
    throw RemuxException('Thiếu VPS trong stream HEVC');
  }
  if (videoSamplesBytes.isEmpty) {
    throw RemuxException('Không có frame video hợp lệ');
  }

  final videoConfig = isH265
      ? buildH265Config(vps!, sps, pps)
      : buildH264Config(sps, pps);

  // 2. Tính DTS/PTS đã unwrap.
  final firstTs = videoDts.firstWhere((e) => e != null,
      orElse: () => videoPts.firstWhere((e) => e != null, orElse: () => 0)) ?? 0;
  final dtsUnwrapped = _unwrap(videoDts, firstTs);
  final ptsUnwrapped = _unwrap(videoPts, firstTs);

  // 3. Xử lý audio (nếu có).
  AacParseResult? aac;
  int? audioFirstPts;
  if (demux.audioStreamType != null && demux.audioUnits.isNotEmpty) {
    final builder = BytesBuilder(copy: false);
    for (final u in demux.audioUnits) {
      builder.add(u.data);
    }
    aac = parseAdts(builder.toBytes());
    audioFirstPts = demux.audioUnits
        .firstWhere((u) => u.pts != null, orElse: () => demux.audioUnits.first)
        .pts;
  }

  // 4. Base thời gian chung (90kHz) để giữ A/V sync.
  final videoBase = dtsUnwrapped.first;
  final globalBase = (aac != null && audioFirstPts != null)
      ? (audioFirstPts < videoBase ? audioFirstPts : videoBase)
      : videoBase;

  // 5. Tạo sample video.
  final videoSamples = <Mp4Sample>[];
  for (var i = 0; i < videoSamplesBytes.length; i++) {
    final dts = dtsUnwrapped[i] - globalBase;
    final cts = ptsUnwrapped[i] - dtsUnwrapped[i];
    final duration = i + 1 < dtsUnwrapped.length
        ? (dtsUnwrapped[i + 1] - dtsUnwrapped[i])
        : (videoSamples.isNotEmpty
            ? videoSamples.last.duration
            : _defaultFrameDuration);
    videoSamples.add(Mp4Sample(
      bytes: videoSamplesBytes[i],
      dts: dts,
      duration: duration > 0 ? duration : _defaultFrameDuration,
      ctsOffset: cts > 0 ? cts : 0,
      isSync: videoIsSync[i],
    ));
  }

  final tracks = <Mp4Track>[
    Mp4Track(
      id: 1,
      isVideo: true,
      timescale: _videoTimescale,
      samples: videoSamples,
      video: videoConfig,
    ),
  ];

  // 6. Tạo track audio.
  if (aac != null && aac.frames.isNotEmpty) {
    final sampleRate = aac.config.sampleRate;
    final startSamples =
        (((audioFirstPts ?? globalBase) - globalBase) * sampleRate / _videoTimescale)
            .round();
    final audioSamples = <Mp4Sample>[];
    var dts = startSamples < 0 ? 0 : startSamples;
    for (final f in aac.frames) {
      audioSamples.add(Mp4Sample(
        bytes: f.data,
        dts: dts,
        duration: 1024, // mỗi frame AAC = 1024 mẫu
        ctsOffset: 0,
        isSync: true,
      ));
      dts += 1024;
    }
    tracks.add(Mp4Track(
      id: 2,
      isVideo: false,
      timescale: sampleRate,
      samples: audioSamples,
      audio: aac.config,
    ));
  }

  return Mp4Muxer(tracks).build();
}
