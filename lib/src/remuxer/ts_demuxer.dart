import 'dart:typed_data';

/// Một đơn vị PES đã được tái lắp (một access unit / frame) kèm mốc thời gian.
class PesUnit {
  final int? pts; // đơn vị 90kHz
  final int? dts; // đơn vị 90kHz
  final Uint8List data; // payload elementary stream (Annex-B cho video)
  PesUnit(this.pts, this.dts, this.data);
}

/// Kết quả demux MPEG-TS.
class TsDemuxResult {
  final int? videoStreamType; // 0x1B = H264, 0x24 = HEVC
  final List<PesUnit> videoUnits;
  final int? audioStreamType; // 0x0F = AAC ADTS
  final List<PesUnit> audioUnits;

  TsDemuxResult({
    required this.videoStreamType,
    required this.videoUnits,
    required this.audioStreamType,
    required this.audioUnits,
  });
}

class _PesAssembler {
  final List<PesUnit> units = [];
  final BytesBuilder _buf = BytesBuilder(copy: false);
  int _len = 0;
  int? _pts;
  int? _dts;

  void _flush() {
    if (_len == 0) return;
    final raw = _buf.toBytes();
    // Tách PES header để lấy phần payload elementary stream.
    if (raw.length > 8 && raw[0] == 0x00 && raw[1] == 0x00 && raw[2] == 0x01) {
      final headerDataLen = raw[8];
      final payloadStart = 9 + headerDataLen;
      if (raw.length > payloadStart) {
        units.add(PesUnit(_pts, _dts,
            Uint8List.sublistView(raw, payloadStart, raw.length)));
      }
    }
    _buf.clear();
    _len = 0;
    _pts = null;
    _dts = null;
  }

  void onPayload(Uint8List payload, bool unitStart) {
    if (unitStart) {
      _flush();
      // Parse PTS/DTS từ PES header mới.
      if (payload.length > 13 &&
          payload[0] == 0x00 &&
          payload[1] == 0x00 &&
          payload[2] == 0x01) {
        final ptsDtsFlags = (payload[7] & 0xC0) >> 6;
        if (ptsDtsFlags == 2 || ptsDtsFlags == 3) {
          _pts = _readTimestamp(payload, 9);
        }
        if (ptsDtsFlags == 3) {
          _dts = _readTimestamp(payload, 14);
        }
      }
    }
    _buf.add(payload);
    _len += payload.length;
  }

  static int _readTimestamp(Uint8List d, int o) {
    return ((d[o] & 0x0E) << 29) |
        (d[o + 1] << 22) |
        ((d[o + 2] & 0xFE) << 14) |
        (d[o + 3] << 7) |
        ((d[o + 4] & 0xFE) >> 1);
  }

  void finish() => _flush();
}

/// Demux một buffer MPEG-TS (đã ghép từ nhiều segment) thành các track ES.
TsDemuxResult demuxTs(Uint8List ts) {
  int? pmtPid;
  int? videoPid;
  int? audioPid;
  int? videoStreamType;
  int? audioStreamType;

  final videoAsm = _PesAssembler();
  final audioAsm = _PesAssembler();

  // Một số stream có offset đầu (TS sync). Tìm byte sync 0x47 đầu tiên.
  var start = 0;
  while (start < ts.length && ts[start] != 0x47) {
    start++;
  }

  var i = start;
  while (i + 188 <= ts.length) {
    final packet = Uint8List.sublistView(ts, i, i + 188);
    i += 188;

    if (packet[0] != 0x47) {
      // Mất đồng bộ: thử tìm lại sync byte kế tiếp.
      var j = i;
      while (j < ts.length && ts[j] != 0x47) {
        j++;
      }
      i = j;
      continue;
    }

    final payloadUnitStart = (packet[1] & 0x40) != 0;
    final pid = ((packet[1] & 0x1F) << 8) | packet[2];
    final hasAdaptation = (packet[3] & 0x20) != 0;
    final hasPayload = (packet[3] & 0x10) != 0;
    if (!hasPayload) continue;

    final adaptationLen = hasAdaptation ? packet[4] : 0;
    var payloadOffset = 4 + (hasAdaptation ? 1 + adaptationLen : 0);
    if (payloadOffset >= 188) continue;

    if (pid == 0) {
      // PAT
      var p = payloadOffset;
      if (payloadUnitStart) {
        final pointer = packet[p];
        p += 1 + pointer;
      }
      if (p + 12 <= 188 && packet[p] == 0x00) {
        final sectionLength = ((packet[p + 1] & 0x0F) << 8) | packet[p + 2];
        var off = p + 8;
        final end = p + 3 + sectionLength - 4;
        while (off + 4 <= end && off + 4 <= 188) {
          final programNum = (packet[off] << 8) | packet[off + 1];
          final programPid = ((packet[off + 2] & 0x1F) << 8) | packet[off + 3];
          if (programNum != 0) {
            pmtPid = programPid;
            break;
          }
          off += 4;
        }
      }
    } else if (pmtPid != null && pid == pmtPid) {
      // PMT
      var p = payloadOffset;
      if (payloadUnitStart) {
        final pointer = packet[p];
        p += 1 + pointer;
      }
      if (p + 12 <= 188 && packet[p] == 0x02) {
        final sectionLength = ((packet[p + 1] & 0x0F) << 8) | packet[p + 2];
        final programInfoLength =
            ((packet[p + 10] & 0x0F) << 8) | packet[p + 11];
        var streamOff = p + 12 + programInfoLength;
        final end = p + 3 + sectionLength - 4;
        while (streamOff + 5 <= end && streamOff + 5 <= 188) {
          final streamType = packet[streamOff];
          final elemPid =
              ((packet[streamOff + 1] & 0x1F) << 8) | packet[streamOff + 2];
          final esInfoLen =
              ((packet[streamOff + 3] & 0x0F) << 8) | packet[streamOff + 4];

          if (streamType == 0x1B || streamType == 0x24) {
            videoPid ??= elemPid;
            videoStreamType ??= streamType;
          } else if (streamType == 0x0F || streamType == 0x11) {
            audioPid ??= elemPid;
            audioStreamType ??= streamType;
          }
          streamOff += 5 + esInfoLen;
        }
      }
    } else if (videoPid != null && pid == videoPid) {
      videoAsm.onPayload(
          Uint8List.sublistView(packet, payloadOffset, 188), payloadUnitStart);
    } else if (audioPid != null && pid == audioPid) {
      audioAsm.onPayload(
          Uint8List.sublistView(packet, payloadOffset, 188), payloadUnitStart);
    }
  }

  videoAsm.finish();
  audioAsm.finish();

  return TsDemuxResult(
    videoStreamType: videoStreamType,
    videoUnits: videoAsm.units,
    audioStreamType: audioStreamType,
    audioUnits: audioAsm.units,
  );
}
