import 'dart:typed_data';
import 'codecs.dart';

/// Một mẫu (sample) trong track.
class Mp4Sample {
  final Uint8List bytes;
  final int dts; // decode time (track timescale)
  final int duration; // (track timescale)
  final int ctsOffset; // composition offset = pts - dts (video)
  final bool isSync;
  Mp4Sample({
    required this.bytes,
    required this.dts,
    required this.duration,
    required this.ctsOffset,
    required this.isSync,
  });
}

/// Một track đầu vào cho muxer.
class Mp4Track {
  final int id;
  final bool isVideo;
  final int timescale;
  final List<Mp4Sample> samples;

  // Video
  final VideoConfig? video;
  // Audio
  final AudioConfig? audio;

  Mp4Track({
    required this.id,
    required this.isVideo,
    required this.timescale,
    required this.samples,
    this.video,
    this.audio,
  });

  int get totalDuration {
    var d = 0;
    for (final s in samples) {
      d += s.duration;
    }
    return d;
  }
}

const int _movieTimescale = 1000;

/// Ghi một box MP4: size(4) + type(4) + payload.
Uint8List _box(String type, List<int> payload) {
  final size = 8 + payload.length;
  final out = Uint8List(size);
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, size);
  out[4] = type.codeUnitAt(0);
  out[5] = type.codeUnitAt(1);
  out[6] = type.codeUnitAt(2);
  out[7] = type.codeUnitAt(3);
  out.setRange(8, size, payload);
  return out;
}

Uint8List _concat(List<List<int>> parts) {
  var total = 0;
  for (final p in parts) {
    total += p.length;
  }
  final out = Uint8List(total);
  var off = 0;
  for (final p in parts) {
    out.setRange(off, off + p.length, p);
    off += p.length;
  }
  return out;
}

List<int> _u32(int v) =>
    [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
List<int> _u16(int v) => [(v >> 8) & 0xFF, v & 0xFF];
List<int> _u64(int v) => [..._u32((v >> 32) & 0xFFFFFFFF), ..._u32(v & 0xFFFFFFFF)];

/// Builder MP4 progressive (ftyp + moov + mdat) với moov đặt trước (faststart).
class Mp4Muxer {
  final List<Mp4Track> tracks;
  Mp4Muxer(this.tracks);

  /// Trả về toàn bộ bytes của file MP4.
  Uint8List build() {
    // 1. Tạo thứ tự interleave theo thời gian (giây) để A/V xen kẽ.
    final order = <List<int>>[]; // [trackIndex, sampleIndex]
    for (var t = 0; t < tracks.length; t++) {
      for (var s = 0; s < tracks[t].samples.length; s++) {
        order.add([t, s]);
      }
    }
    order.sort((a, b) {
      final ta = tracks[a[0]];
      final tb = tracks[b[0]];
      final sa = ta.samples[a[1]].dts / ta.timescale;
      final sb = tb.samples[b[1]].dts / tb.timescale;
      return sa.compareTo(sb);
    });

    // 2. Tính kích thước mdat và offset tương đối từng sample.
    // offset[t][s] tương đối so với đầu phần dữ liệu mdat.
    final relOffsets =
        List.generate(tracks.length, (t) => List<int>.filled(tracks[t].samples.length, 0));
    var mdatDataSize = 0;
    for (final pair in order) {
      relOffsets[pair[0]][pair[1]] = mdatDataSize;
      mdatDataSize += tracks[pair[0]].samples[pair[1]].bytes.length;
    }

    final useLargeOffset = mdatDataSize > 0xFFFFFFF0;

    // 3. Build moov với base=0 để đo kích thước, rồi build lại với base đúng.
    final ftyp = _buildFtyp();
    var moov = _buildMoov(relOffsets, base: 0, large: useLargeOffset);

    // mdat header: 8 byte (hoặc 16 nếu cần 64-bit largesize)
    final mdatHeaderSize = mdatDataSize + 8 > 0xFFFFFFFF ? 16 : 8;
    final mdatBase = ftyp.length + moov.length + mdatHeaderSize;

    moov = _buildMoov(relOffsets, base: mdatBase, large: useLargeOffset);

    // 4. Build mdat.
    final mdat = _buildMdat(order, mdatDataSize, mdatHeaderSize);

    return _concat([ftyp, moov, mdat]);
  }

  Uint8List _buildFtyp() {
    final payload = <int>[];
    payload.addAll('isom'.codeUnits); // major_brand
    payload.addAll(_u32(512)); // minor_version
    payload.addAll('isom'.codeUnits);
    payload.addAll('iso2'.codeUnits);
    payload.addAll('avc1'.codeUnits);
    payload.addAll('mp41'.codeUnits);
    return _box('ftyp', payload);
  }

  Uint8List _buildMdat(List<List<int>> order, int dataSize, int headerSize) {
    final out = Uint8List(headerSize + dataSize);
    final bd = ByteData.sublistView(out);
    if (headerSize == 16) {
      bd.setUint32(0, 1); // size=1 -> dùng largesize
      out[4] = 'm'.codeUnitAt(0);
      out[5] = 'd'.codeUnitAt(0);
      out[6] = 'a'.codeUnitAt(0);
      out[7] = 't'.codeUnitAt(0);
      bd.setUint64(8, headerSize + dataSize);
    } else {
      bd.setUint32(0, headerSize + dataSize);
      out[4] = 'm'.codeUnitAt(0);
      out[5] = 'd'.codeUnitAt(0);
      out[6] = 'a'.codeUnitAt(0);
      out[7] = 't'.codeUnitAt(0);
    }
    var off = headerSize;
    for (final pair in order) {
      final bytes = tracks[pair[0]].samples[pair[1]].bytes;
      out.setRange(off, off + bytes.length, bytes);
      off += bytes.length;
    }
    return out;
  }

  Uint8List _buildMoov(List<List<int>> relOffsets,
      {required int base, required bool large}) {
    final parts = <List<int>>[_buildMvhd()];
    for (var t = 0; t < tracks.length; t++) {
      parts.add(_buildTrak(t, relOffsets[t], base, large));
    }
    return _box('moov', _concat(parts));
  }

  Uint8List _buildMvhd() {
    var maxDurMs = 0;
    for (final t in tracks) {
      final ms = (t.totalDuration * _movieTimescale / t.timescale).round();
      if (ms > maxDurMs) maxDurMs = ms;
    }
    final p = <int>[];
    p.addAll(_u32(0)); // version + flags
    p.addAll(_u32(0)); // creation_time
    p.addAll(_u32(0)); // modification_time
    p.addAll(_u32(_movieTimescale));
    p.addAll(_u32(maxDurMs));
    p.addAll(_u32(0x00010000)); // rate 1.0
    p.addAll(_u16(0x0100)); // volume 1.0
    p.addAll(_u16(0)); // reserved
    p.addAll(_u32(0));
    p.addAll(_u32(0)); // reserved
    // unity matrix
    p.addAll(_u32(0x00010000));
    p.addAll(_u32(0));
    p.addAll(_u32(0));
    p.addAll(_u32(0));
    p.addAll(_u32(0x00010000));
    p.addAll(_u32(0));
    p.addAll(_u32(0));
    p.addAll(_u32(0));
    p.addAll(_u32(0x40000000));
    for (var i = 0; i < 6; i++) {
      p.addAll(_u32(0)); // pre_defined
    }
    p.addAll(_u32(tracks.length + 1)); // next_track_ID
    return _box('mvhd', p);
  }

  Uint8List _buildTrak(int t, List<int> relOffsets, int base, bool large) {
    final track = tracks[t];
    final tkhd = _buildTkhd(track);
    final mdia = _buildMdia(track, relOffsets, base, large);
    return _box('trak', _concat([tkhd, mdia]));
  }

  Uint8List _buildTkhd(Mp4Track track) {
    final durMs =
        (track.totalDuration * _movieTimescale / track.timescale).round();
    final p = <int>[];
    p.addAll([0, 0, 0, 0x07]); // version 0, flags = enabled|in_movie|in_preview
    p.addAll(_u32(0)); // creation_time
    p.addAll(_u32(0)); // modification_time
    p.addAll(_u32(track.id));
    p.addAll(_u32(0)); // reserved
    p.addAll(_u32(durMs));
    p.addAll(_u32(0));
    p.addAll(_u32(0)); // reserved
    p.addAll(_u16(0)); // layer
    p.addAll(_u16(0)); // alternate_group
    p.addAll(_u16(track.isVideo ? 0 : 0x0100)); // volume
    p.addAll(_u16(0)); // reserved
    // unity matrix
    p.addAll(_u32(0x00010000));
    p.addAll(_u32(0));
    p.addAll(_u32(0));
    p.addAll(_u32(0));
    p.addAll(_u32(0x00010000));
    p.addAll(_u32(0));
    p.addAll(_u32(0));
    p.addAll(_u32(0));
    p.addAll(_u32(0x40000000));
    final w = track.isVideo ? track.video!.width : 0;
    final h = track.isVideo ? track.video!.height : 0;
    p.addAll(_u32(w << 16)); // width 16.16
    p.addAll(_u32(h << 16)); // height 16.16
    return _box('tkhd', p);
  }

  Uint8List _buildMdia(
      Mp4Track track, List<int> relOffsets, int base, bool large) {
    final mdhd = _buildMdhd(track);
    final hdlr = _buildHdlr(track);
    final minf = _buildMinf(track, relOffsets, base, large);
    return _box('mdia', _concat([mdhd, hdlr, minf]));
  }

  Uint8List _buildMdhd(Mp4Track track) {
    final p = <int>[];
    p.addAll(_u32(0)); // version + flags
    p.addAll(_u32(0)); // creation
    p.addAll(_u32(0)); // modification
    p.addAll(_u32(track.timescale));
    p.addAll(_u32(track.totalDuration));
    p.addAll(_u16(0x55C4)); // language 'und'
    p.addAll(_u16(0)); // pre_defined
    return _box('mdhd', p);
  }

  Uint8List _buildHdlr(Mp4Track track) {
    final p = <int>[];
    p.addAll(_u32(0)); // version + flags
    p.addAll(_u32(0)); // pre_defined
    p.addAll((track.isVideo ? 'vide' : 'soun').codeUnits);
    p.addAll(_u32(0));
    p.addAll(_u32(0));
    p.addAll(_u32(0)); // reserved
    p.addAll((track.isVideo ? 'VideoHandler' : 'SoundHandler').codeUnits);
    p.add(0); // null terminator
    return _box('hdlr', p);
  }

  Uint8List _buildMinf(
      Mp4Track track, List<int> relOffsets, int base, bool large) {
    final header = track.isVideo
        ? _box('vmhd', [
            0, 0, 0, 0x01, // version + flags=1
            ..._u16(0), // graphicsmode
            ..._u16(0), ..._u16(0), ..._u16(0), // opcolor
          ])
        : _box('smhd', [
            0, 0, 0, 0, // version + flags
            ..._u16(0), // balance
            ..._u16(0), // reserved
          ]);
    final dinf = _buildDinf();
    final stbl = _buildStbl(track, relOffsets, base, large);
    return _box('minf', _concat([header, dinf, stbl]));
  }

  Uint8List _buildDinf() {
    final urlBox = _box('url ', [0, 0, 0, 0x01]); // flags=1 self-contained
    final dref = _box('dref', [
      0, 0, 0, 0, // version + flags
      ..._u32(1), // entry_count
      ...urlBox,
    ]);
    return _box('dinf', dref);
  }

  Uint8List _buildStbl(
      Mp4Track track, List<int> relOffsets, int base, bool large) {
    final stsd = _buildStsd(track);
    final stts = _buildStts(track);
    final stsc = _box('stsc', [
      0, 0, 0, 0,
      ..._u32(1), // entry_count
      ..._u32(1), // first_chunk
      ..._u32(1), // samples_per_chunk
      ..._u32(1), // sample_description_index
    ]);
    final stsz = _buildStsz(track);
    final stco = _buildChunkOffsets(track, relOffsets, base, large);

    final parts = <List<int>>[stsd, stts];
    if (track.isVideo) {
      final ctts = _buildCtts(track);
      if (ctts != null) parts.add(ctts);
      final stss = _buildStss(track);
      if (stss != null) parts.add(stss);
    }
    parts.add(stsc);
    parts.add(stsz);
    parts.add(stco);
    return _box('stbl', _concat(parts));
  }

  Uint8List _buildStsd(Mp4Track track) {
    final List<int> entry;
    if (track.isVideo) {
      entry = _buildVisualSampleEntry(track.video!);
    } else {
      entry = _buildAudioSampleEntry(track.audio!);
    }
    return _box('stsd', [
      0, 0, 0, 0, // version + flags
      ..._u32(1), // entry_count
      ...entry,
    ]);
  }

  List<int> _buildVisualSampleEntry(VideoConfig v) {
    final type = v.codec == VideoCodec.h264 ? 'avc1' : 'hvc1';
    final configType = v.codec == VideoCodec.h264 ? 'avcC' : 'hvcC';
    final p = <int>[];
    p.addAll([0, 0, 0, 0, 0, 0]); // reserved
    p.addAll(_u16(1)); // data_reference_index
    p.addAll(_u16(0)); // pre_defined
    p.addAll(_u16(0)); // reserved
    p.addAll(_u32(0));
    p.addAll(_u32(0));
    p.addAll(_u32(0)); // pre_defined
    p.addAll(_u16(v.width));
    p.addAll(_u16(v.height));
    p.addAll(_u32(0x00480000)); // horizresolution 72dpi
    p.addAll(_u32(0x00480000)); // vertresolution
    p.addAll(_u32(0)); // reserved
    p.addAll(_u16(1)); // frame_count
    p.addAll(List.filled(32, 0)); // compressorname
    p.addAll(_u16(0x0018)); // depth
    p.addAll(_u16(0xFFFF)); // pre_defined
    final configBox = _box(configType, v.configBox);
    p.addAll(configBox);
    return _box(type, p);
  }

  List<int> _buildAudioSampleEntry(AudioConfig a) {
    final p = <int>[];
    p.addAll([0, 0, 0, 0, 0, 0]); // reserved
    p.addAll(_u16(1)); // data_reference_index
    p.addAll(_u32(0)); // reserved
    p.addAll(_u32(0));
    p.addAll(_u16(a.channelCount == 0 ? 2 : a.channelCount));
    p.addAll(_u16(16)); // samplesize
    p.addAll(_u16(0)); // pre_defined
    p.addAll(_u16(0)); // reserved
    p.addAll(_u32(a.sampleRate << 16)); // samplerate 16.16
    p.addAll(_buildEsds(a));
    return _box('mp4a', p);
  }

  List<int> _buildEsds(AudioConfig a) {
    final asc = a.buildAudioSpecificConfig();
    // DecoderSpecificInfo (tag 0x05)
    final dsi = <int>[0x05, asc.length, ...asc];
    // DecoderConfigDescriptor (tag 0x04)
    final dcd = <int>[
      0x04,
      13 + dsi.length,
      0x40, // objectTypeIndication = Audio ISO/IEC 14496-3
      0x15, // streamType(6)=5 audio, upstream(1)=0, reserved(1)=1
      0, 0, 0, // bufferSizeDB
      ..._u32(0), // maxBitrate
      ..._u32(0), // avgBitrate
      ...dsi,
    ];
    // SLConfigDescriptor (tag 0x06)
    final sl = <int>[0x06, 0x01, 0x02];
    // ES_Descriptor (tag 0x03)
    final esLen = 3 + dcd.length + sl.length;
    final es = <int>[
      0x03,
      esLen,
      ..._u16(0), // ES_ID
      0x00, // flags
      ...dcd,
      ...sl,
    ];
    return _box('esds', [0, 0, 0, 0, ...es]);
  }

  Uint8List _buildStts(Mp4Track track) {
    // Gộp các delta liên tiếp giống nhau.
    final entries = <List<int>>[];
    for (final s in track.samples) {
      if (entries.isNotEmpty && entries.last[1] == s.duration) {
        entries.last[0]++;
      } else {
        entries.add([1, s.duration]);
      }
    }
    final p = <int>[0, 0, 0, 0, ..._u32(entries.length)];
    for (final e in entries) {
      p.addAll(_u32(e[0]));
      p.addAll(_u32(e[1]));
    }
    return _box('stts', p);
  }

  Uint8List? _buildCtts(Mp4Track track) {
    var hasOffset = false;
    for (final s in track.samples) {
      if (s.ctsOffset != 0) {
        hasOffset = true;
        break;
      }
    }
    if (!hasOffset) return null;
    final entries = <List<int>>[];
    for (final s in track.samples) {
      if (entries.isNotEmpty && entries.last[1] == s.ctsOffset) {
        entries.last[0]++;
      } else {
        entries.add([1, s.ctsOffset]);
      }
    }
    final p = <int>[0, 0, 0, 0, ..._u32(entries.length)];
    for (final e in entries) {
      p.addAll(_u32(e[0]));
      p.addAll(_u32(e[1])); // version 0: unsigned offset
    }
    return _box('ctts', p);
  }

  Uint8List? _buildStss(Mp4Track track) {
    final syncs = <int>[];
    for (var i = 0; i < track.samples.length; i++) {
      if (track.samples[i].isSync) syncs.add(i + 1);
    }
    if (syncs.isEmpty || syncs.length == track.samples.length) {
      return null; // tất cả là sync -> không cần stss
    }
    final p = <int>[0, 0, 0, 0, ..._u32(syncs.length)];
    for (final s in syncs) {
      p.addAll(_u32(s));
    }
    return _box('stss', p);
  }

  Uint8List _buildStsz(Mp4Track track) {
    final p = <int>[
      0, 0, 0, 0,
      ..._u32(0), // sample_size = 0 -> dùng bảng
      ..._u32(track.samples.length),
    ];
    for (final s in track.samples) {
      p.addAll(_u32(s.bytes.length));
    }
    return _box('stsz', p);
  }

  Uint8List _buildChunkOffsets(
      Mp4Track track, List<int> relOffsets, int base, bool large) {
    if (large) {
      final p = <int>[0, 0, 0, 0, ..._u32(relOffsets.length)];
      for (final off in relOffsets) {
        p.addAll(_u64(base + off));
      }
      return _box('co64', p);
    } else {
      final p = <int>[0, 0, 0, 0, ..._u32(relOffsets.length)];
      for (final off in relOffsets) {
        p.addAll(_u32(base + off));
      }
      return _box('stco', p);
    }
  }
}
