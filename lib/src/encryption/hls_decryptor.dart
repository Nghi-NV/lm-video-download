import 'dart:typed_data';
import 'package:encrypt/encrypt.dart' as enc;
import '../parser/hls_parser.dart';

/// Bộ giải mã phân đoạn HLS sử dụng AES-128.
class HlsDecryptor {
  /// Giải mã một mảng byte của segment dựa trên thông tin khóa và số thứ tự segment.
  static Uint8List decrypt({
    required Uint8List encryptedData,
    required Uint8List keyBytes,
    required HlsEncryptionKey keyConfig,
    required int segmentIndex,
    required int mediaSequenceStart,
  }) {
    if (keyBytes.length != 16) {
      throw Exception(
          'Độ dài khóa AES phải là 16 bytes, nhưng nhận được: ${keyBytes.length}');
    }

    // 1. Xác định IV (Initialization Vector)
    Uint8List ivBytes;
    if (keyConfig.ivHex != null && keyConfig.ivHex!.isNotEmpty) {
      ivBytes = _parseIvHex(keyConfig.ivHex!);
    } else {
      // Nếu không chỉ định IV, IV mặc định sẽ là số thứ tự phân đoạn (sequence number) dạng 16 bytes
      final sequenceNumber = mediaSequenceStart + segmentIndex;
      ivBytes = _generateIvFromSequence(sequenceNumber);
    }

    // 2. Thực hiện giải mã AES-128-CBC
    try {
      final key = enc.Key(keyBytes);
      final iv = enc.IV(ivBytes);

      // HLS AES-128 sử dụng AES-128-CBC với padding PKCS7
      final decrypter = enc.Encrypter(
        enc.AES(key, mode: enc.AESMode.cbc, padding: 'PKCS7'),
      );

      final decryptedBytes = decrypter.decryptBytes(
        enc.Encrypted(encryptedData),
        iv: iv,
      );

      return Uint8List.fromList(decryptedBytes);
    } catch (e) {
      throw Exception('Lỗi trong quá trình giải mã AES-128: $e');
    }
  }

  /// Parse chuỗi hex IV (ví dụ: "0x00000000000000000000000000000001" hoặc "00000000000000000000000000000001") thành bytes.
  static Uint8List _parseIvHex(String ivHex) {
    String cleanHex = ivHex.trim();
    if (cleanHex.startsWith('0x') || cleanHex.startsWith('0X')) {
      cleanHex = cleanHex.substring(2);
    }

    // Đảm bảo độ dài là 32 ký tự hex (tương đương 16 bytes)
    cleanHex = cleanHex.padLeft(32, '0');

    final bytes = Uint8List(16);
    for (int i = 0; i < 16; i++) {
      final hexByte = cleanHex.substring(i * 2, i * 2 + 2);
      bytes[i] = int.parse(hexByte, radix: 16);
    }

    return bytes;
  }

  /// Tạo IV 16 bytes từ số thứ tự phân đoạn (HLS Spec).
  static Uint8List _generateIvFromSequence(int sequenceNumber) {
    final bytes = Uint8List(16);
    final byteData = ByteData.sublistView(bytes);

    // Ghi số thứ tự dưới dạng số nguyên 64-bit ở 8 bytes cuối của mảng 16 bytes (Big Endian)
    byteData.setUint64(8, sequenceNumber, Endian.big);

    return bytes;
  }
}
