import 'dart:typed_data';

/// Bộ đọc bit MSB-first dùng để phân tích các cú pháp NAL (SPS/PPS) theo
/// chuẩn H.264/H.265. Hỗ trợ Exp-Golomb (ue/se) và bỏ qua emulation
/// prevention bytes (0x03) khi chuyển NAL -> RBSP.
class BitReader {
  final Uint8List _data;
  int _bytePos = 0;
  int _bitPos = 0;

  BitReader(this._data);

  /// Chuyển một NAL payload (đã bỏ NAL header) sang RBSP bằng cách loại bỏ
  /// các byte emulation prevention 0x00 0x00 0x03.
  static Uint8List ebspToRbsp(Uint8List ebsp) {
    final out = BytesBuilder(copy: false);
    final n = ebsp.length;
    var zeros = 0;
    final buf = Uint8List(n);
    var len = 0;
    for (var i = 0; i < n; i++) {
      final b = ebsp[i];
      if (zeros >= 2 && b == 0x03) {
        // Bỏ emulation byte, reset đếm số 0
        zeros = 0;
        continue;
      }
      buf[len++] = b;
      if (b == 0x00) {
        zeros++;
      } else {
        zeros = 0;
      }
    }
    out.add(Uint8List.sublistView(buf, 0, len));
    return out.toBytes();
  }

  bool get hasMoreData => _bytePos < _data.length;

  int readBit() {
    if (_bytePos >= _data.length) return 0;
    final bit = (_data[_bytePos] >> (7 - _bitPos)) & 0x01;
    _bitPos++;
    if (_bitPos == 8) {
      _bitPos = 0;
      _bytePos++;
    }
    return bit;
  }

  int readBits(int n) {
    var v = 0;
    for (var i = 0; i < n; i++) {
      v = (v << 1) | readBit();
    }
    return v;
  }

  /// Unsigned Exp-Golomb.
  int readUE() {
    var leadingZeros = 0;
    while (hasMoreData && readBit() == 0) {
      leadingZeros++;
      if (leadingZeros > 31) break;
    }
    if (leadingZeros == 0) return 0;
    final suffix = readBits(leadingZeros);
    return (1 << leadingZeros) - 1 + suffix;
  }

  /// Signed Exp-Golomb.
  int readSE() {
    final ue = readUE();
    if (ue == 0) return 0;
    final sign = (ue & 1) == 1 ? 1 : -1;
    return sign * ((ue + 1) >> 1);
  }

  void skipBits(int n) {
    for (var i = 0; i < n; i++) {
      readBit();
    }
  }
}
