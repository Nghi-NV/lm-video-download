import '../models/models.dart';

/// Bộ phân tích cú pháp tệp M3U8 HLS thuần Dart.
class HlsParser {
  /// Giải quyết URL tương đối (relative URL) dựa trên URL cơ sở (base URL).
  static String resolveUrl(String baseUrl, String relativeUrl) {
    if (relativeUrl.startsWith('http://') ||
        relativeUrl.startsWith('https://')) {
      return relativeUrl;
    }

    final baseUri = Uri.parse(baseUrl);
    // Nếu relativeUrl bắt đầu bằng '/' -> đi từ gốc domain
    if (relativeUrl.startsWith('/')) {
      return '${baseUri.scheme}://${baseUri.host}${baseUri.hasPort ? ":${baseUri.port}" : ""}$relativeUrl';
    }

    // Ngược lại đi từ thư mục hiện tại của URL cơ sở
    final segments = List<String>.from(baseUri.pathSegments);
    if (segments.isNotEmpty) {
      segments.removeLast(); // Xóa phần tên file m3u8 hiện tại
    }

    final newPath = (segments..addAll(relativeUrl.split('/'))).join('/');
    return '${baseUri.scheme}://${baseUri.host}${baseUri.hasPort ? ":${baseUri.port}" : ""}/$newPath';
  }

  /// Kiểm tra xem nội dung m3u8 có phải là Master Playlist hay không.
  static bool isMasterPlaylist(String content) {
    return content.contains('#EXT-X-STREAM-INF');
  }

  /// Parse Master Playlist để trích xuất các variant streams.
  static List<HlsVariantStream> parseMasterPlaylist(
      String content, String playlistUrl) {
    final List<HlsVariantStream> streams = [];
    final lines = content.split('\n');

    int? currentBandwidth;
    String? currentResolution;
    String? currentCodecs;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        // Parse attributes
        final attributesStr = line.substring('#EXT-X-STREAM-INF:'.length);
        final attributes = _parseAttributes(attributesStr);

        currentBandwidth = int.tryParse(attributes['BANDWIDTH'] ?? '');
        currentResolution = attributes['RESOLUTION']?.replaceAll('"', '');
        currentCodecs = attributes['CODECS']?.replaceAll('"', '');
      } else if (!line.startsWith('#') &&
          (currentBandwidth != null || currentResolution != null)) {
        // Đây là dòng chứa URL của variant playlist tương ứng
        final streamUrl = resolveUrl(playlistUrl, line);
        streams.add(HlsVariantStream(
          url: streamUrl,
          bandwidth: currentBandwidth,
          resolution: currentResolution,
          codecs: currentCodecs,
        ));

        currentBandwidth = null;
        currentResolution = null;
        currentCodecs = null;
      }
    }

    // Sắp xếp các stream theo chất lượng (băng thông/độ phân giải) giảm dần
    streams.sort((a, b) => (b.bandwidth ?? 0).compareTo(a.bandwidth ?? 0));
    return streams;
  }

  /// Lớp chứa kết quả parse của Media Playlist.
  static HlsMediaPlaylist parseMediaPlaylist(
      String content, String playlistUrl) {
    final List<String> segments = [];
    final lines = content.split('\n');

    int mediaSequence = 0;
    HlsEncryptionKey? encryptionKey;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        mediaSequence =
            int.tryParse(line.substring('#EXT-X-MEDIA-SEQUENCE:'.length)) ?? 0;
      } else if (line.startsWith('#EXT-X-KEY:')) {
        final attributesStr = line.substring('#EXT-X-KEY:'.length);
        final attributes = _parseAttributes(attributesStr);

        final method = attributes['METHOD'];
        if (method == 'AES-128') {
          final keyUri = attributes['URI']?.replaceAll('"', '');
          final ivStr = attributes['IV']?.replaceAll('"', '');

          if (keyUri != null) {
            final absoluteKeyUrl = resolveUrl(playlistUrl, keyUri);
            encryptionKey = HlsEncryptionKey(
              method: method!,
              url: absoluteKeyUrl,
              ivHex: ivStr,
            );
          }
        }
      } else if (!line.startsWith('#')) {
        // Dòng này chứa URL segment
        final segmentUrl = resolveUrl(playlistUrl, line);
        segments.add(segmentUrl);
      }
    }

    return HlsMediaPlaylist(
      segments: segments,
      mediaSequence: mediaSequence,
      encryptionKey: encryptionKey,
    );
  }

  /// Parse cặp Key=Value phân tách bằng dấu phẩy trong dòng chỉ thị của M3U8.
  static Map<String, String> _parseAttributes(String attributeString) {
    final Map<String, String> attributes = {};

    // Regex hỗ trợ parse thuộc tính: KEY=VALUE hoặc KEY="VALUE"
    final regExp = RegExp(r'([A-Z0-9\-]+)\s*=\s*(?:"([^"]*)"|([^,]*))');
    final matches = regExp.allMatches(attributeString);

    for (final match in matches) {
      final key = match.group(1);
      final value = match.group(2) ?? match.group(3);
      if (key != null && value != null) {
        attributes[key] = value.trim();
      }
    }

    return attributes;
  }
}

/// Thông tin giải mã của HLS.
class HlsEncryptionKey {
  final String method;
  final String url;
  final String? ivHex; // Dạng hex "0x0001..."

  HlsEncryptionKey({
    required this.method,
    required this.url,
    this.ivHex,
  });

  @override
  String toString() =>
      'HlsEncryptionKey(method: $method, url: $url, iv: $ivHex)';
}

/// Lớp đại diện cho một danh sách phát phân đoạn HLS.
class HlsMediaPlaylist {
  final List<String> segments;
  final int mediaSequence;
  final HlsEncryptionKey? encryptionKey;

  HlsMediaPlaylist({
    required this.segments,
    required this.mediaSequence,
    this.encryptionKey,
  });
}
