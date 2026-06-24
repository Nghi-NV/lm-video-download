// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:lm_video_download/lm_video_download.dart';

/// Kiểm tra một box type có tồn tại trong buffer MP4 không (tìm thô theo 4CC).
bool _containsBox(Uint8List data, String fourcc) {
  final needle = fourcc.codeUnits;
  for (var i = 0; i + 4 <= data.length; i++) {
    if (data[i] == needle[0] &&
        data[i + 1] == needle[1] &&
        data[i + 2] == needle[2] &&
        data[i + 3] == needle[3]) {
      return true;
    }
  }
  return false;
}

void main() {
  test('Remux HEVC segment_bizfly.ts -> MP4 hợp lệ (pure Dart)', () {
    final tsFile = File('segment_bizfly.ts');
    if (!tsFile.existsSync()) {
      print('Bỏ qua: không tìm thấy segment_bizfly.ts');
      return;
    }

    final ts = tsFile.readAsBytesSync();
    final mp4 = remuxTsToMp4(ts);

    expect(mp4.length, greaterThan(8));

    // ftyp box ngay đầu file (faststart).
    final magic = String.fromCharCodes(mp4.sublist(4, 8));
    expect(magic, equals('ftyp'), reason: 'File phải bắt đầu bằng ftyp box');

    // Phải có moov + mdat + cấu hình HEVC.
    expect(_containsBox(mp4, 'moov'), isTrue, reason: 'Thiếu moov');
    expect(_containsBox(mp4, 'mdat'), isTrue, reason: 'Thiếu mdat');
    expect(_containsBox(mp4, 'hvc1'), isTrue, reason: 'Thiếu sample entry hvc1');
    expect(_containsBox(mp4, 'hvcC'), isTrue,
        reason: 'Thiếu hvcC (VPS/SPS/PPS) — file sẽ không decode được');

    // moov phải nằm trước mdat (faststart).
    final moovPos = _indexOf(mp4, 'moov');
    final mdatPos = _indexOf(mp4, 'mdat');
    expect(moovPos, lessThan(mdatPos),
        reason: 'moov phải đặt trước mdat để stream/play ngay');
  });

  test('Remux ném RemuxException khi không có video', () {
    // Buffer rác không phải TS hợp lệ.
    final junk = Uint8List(376); // 2 TS packet rỗng (không có 0x47)
    expect(() => remuxTsToMp4(junk), throwsA(isA<RemuxException>()));
  });
}

int _indexOf(Uint8List data, String fourcc) {
  final needle = fourcc.codeUnits;
  for (var i = 0; i + 4 <= data.length; i++) {
    if (data[i] == needle[0] &&
        data[i + 1] == needle[1] &&
        data[i + 2] == needle[2] &&
        data[i + 3] == needle[3]) {
      return i;
    }
  }
  return -1;
}
