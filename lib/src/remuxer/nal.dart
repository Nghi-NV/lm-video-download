import 'dart:typed_data';

/// Tách một buffer Annex-B thành các NAL unit (không gồm start code).
List<Uint8List> splitAnnexB(Uint8List data) {
  final nals = <Uint8List>[];
  final n = data.length;

  // Tìm start code đầu tiên.
  int findStart(int from) {
    var j = from;
    while (j + 3 <= n) {
      if (data[j] == 0 && data[j + 1] == 0 && data[j + 2] == 1) {
        return j; // độ dài start code = 3
      }
      j++;
    }
    return -1;
  }

  var sc = findStart(0);
  while (sc != -1) {
    final nalStart = sc + 3;
    final next = findStart(nalStart);
    var nalEnd = next == -1 ? n : next;
    // Loại 1 byte 0x00 phía trước start code 4-byte (00 00 00 01).
    if (next != -1 && nalEnd > nalStart && data[nalEnd - 1] == 0) {
      nalEnd--;
    }
    if (nalEnd > nalStart) {
      nals.add(Uint8List.sublistView(data, nalStart, nalEnd));
    }
    sc = next;
  }
  return nals;
}

/// Chuyển danh sách NAL thành định dạng length-prefixed (4 byte big-endian) cho
/// mẫu MP4 (avc1/hvc1).
Uint8List toLengthPrefixed(List<Uint8List> nals) {
  var total = 0;
  for (final nal in nals) {
    total += 4 + nal.length;
  }
  final out = Uint8List(total);
  var off = 0;
  for (final nal in nals) {
    final len = nal.length;
    out[off] = (len >> 24) & 0xFF;
    out[off + 1] = (len >> 16) & 0xFF;
    out[off + 2] = (len >> 8) & 0xFF;
    out[off + 3] = len & 0xFF;
    off += 4;
    out.setRange(off, off + len, nal);
    off += len;
  }
  return out;
}
