// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:lm_video_download/lm_video_download.dart';

// Conditionally import package:web for Web-compatible Blob download
import 'package:web/web.dart' as web;
import 'dart:js_interop';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Khởi tạo Downloader nếu không phải Web (vì Mobile/Desktop cần local storage & DB)
  if (!kIsWeb) {
    await HlsDownloader.instance.initialize(
      maxConcurrentDownloads: 5,
      enableLogging: true,
    );
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lumi HLS Downloader',
      theme: ThemeData.dark().copyWith(
        primaryColor: Colors.deepPurpleAccent,
        scaffoldBackgroundColor: const Color(0xFF0F0B1E),
        colorScheme: const ColorScheme.dark(
          primary: Colors.deepPurpleAccent,
          secondary: Colors.pinkAccent,
          surface: Color(0xFF1D1836),
        ),
      ),
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _urlController = TextEditingController(
    text:
        'https://playertest.longtailvideo.com/adaptive/bipbop/gear1/prog_index.m3u8',
  );

  bool _isDownloading = false;
  double _progress = 0.0;
  String _statusMessage = 'Sẵn sàng tải xuống';
  String _downloadSpeed = '0.0 KB/s';
  int _downloadedSegs = 0;
  int _totalSegs = 0;

  HlsDownloadTask? _activeNativeTask;
  late AnimationController _glowController;

  @override
  void initState() {
    super.initState();
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _glowController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  /// Trình tải HLS tối ưu cho Web (chạy in-memory, sau đó trigger Browser Download)
  Future<void> _startWebDownload(String url) async {
    setState(() {
      _isDownloading = true;
      _progress = 0.0;
      _downloadedSegs = 0;
      _totalSegs = 0;
      _downloadSpeed = '---';
      _statusMessage = 'Đang tải file playlist...';
    });

    try {
      // 1. Fetch playlist m3u8
      final playlistResponse = await http.get(Uri.parse(url));
      if (playlistResponse.statusCode != 200) {
        throw Exception(
            'Lỗi kết nối URL m3u8 (HTTP ${playlistResponse.statusCode})');
      }
      String m3u8Content = playlistResponse.body;

      // 2. Parse Master Playlist nếu cần
      if (HlsParser.isMasterPlaylist(m3u8Content)) {
        final variants = HlsParser.parseMasterPlaylist(m3u8Content, url);
        if (variants.isEmpty) {
          throw Exception('Master playlist không có luồng video hợp lệ');
        }
        final bestUrl = variants.first.url;
        final res = await http.get(Uri.parse(bestUrl));
        m3u8Content = res.body;
      }

      // 3. Parse Media Playlist
      final mediaPlaylist = HlsParser.parseMediaPlaylist(m3u8Content, url);
      if (mediaPlaylist.segments.isEmpty) {
        throw Exception('Playlist không chứa phân đoạn video nào');
      }

      final totalSegments = mediaPlaylist.segments.length;
      setState(() {
        _totalSegs = totalSegments;
        _statusMessage = 'Đang khởi tạo luồng giải mã & tải song song...';
      });

      // 4. Tải khóa giải mã AES-128 nếu có
      Uint8List? keyBytes;
      if (mediaPlaylist.encryptionKey != null) {
        final keyRes =
            await http.get(Uri.parse(mediaPlaylist.encryptionKey!.url));
        if (keyRes.statusCode == 200) {
          keyBytes = keyRes.bodyBytes;
        } else {
          throw Exception('Không thể tải khóa giải mã AES-128');
        }
      }

      // 5. Tải song song in-memory
      final Map<int, Uint8List> downloadedData = {};
      final List<int> queue = List.generate(totalSegments, (i) => i);
      const concurrentLimit = 5;
      int activeCount = 0;
      final Completer<void> downloadCompleter = Completer<void>();

      final stopwatch = Stopwatch()..start();
      int bytesDownloaded = 0;

      void updateWebProgress() {
        if (!mounted) return;
        final count = downloadedData.length;
        final elapsedSecs = stopwatch.elapsedMilliseconds / 1000;
        final speed =
            elapsedSecs > 0 ? (bytesDownloaded / 1024) / elapsedSecs : 0.0;

        setState(() {
          _downloadedSegs = count;
          _progress = count / totalSegments;
          _downloadSpeed = '${speed.toStringAsFixed(1)} KB/s';
          _statusMessage = 'Đang tải phân đoạn: $count/$totalSegments';
        });
      }

      void processNext() async {
        if (queue.isEmpty) {
          if (activeCount == 0 && !downloadCompleter.isCompleted) {
            downloadCompleter.complete();
          }
          return;
        }

        final idx = queue.removeAt(0);
        activeCount++;

        try {
          final segRes = await http.get(Uri.parse(mediaPlaylist.segments[idx]));
          if (segRes.statusCode == 200) {
            Uint8List segmentBytes = segRes.bodyBytes;

            // Giải mã cục bộ nếu được mã hóa
            if (keyBytes != null && mediaPlaylist.encryptionKey != null) {
              segmentBytes = HlsDecryptor.decrypt(
                encryptedData: segmentBytes,
                keyBytes: keyBytes,
                keyConfig: mediaPlaylist.encryptionKey!,
                segmentIndex: idx,
                mediaSequenceStart: mediaPlaylist.mediaSequence,
              );
            }

            downloadedData[idx] = segmentBytes;
            bytesDownloaded += segmentBytes.length;
            updateWebProgress();
          } else {
            throw Exception('Lỗi HTTP ${segRes.statusCode} ở segment $idx');
          }
        } catch (e) {
          if (!downloadCompleter.isCompleted) {
            downloadCompleter.completeError(e);
          }
          return;
        }

        activeCount--;
        processNext();
      }

      for (int i = 0; i < concurrentLimit && i < totalSegments; i++) {
        processNext();
      }

      await downloadCompleter.future;
      stopwatch.stop();

      // 6. Ghép file trong bộ nhớ
      setState(() {
        _statusMessage = 'Đang biên dịch tệp video trong bộ nhớ...';
      });

      final builder = BytesBuilder();
      for (int i = 0; i < totalSegments; i++) {
        final data = downloadedData[i];
        if (data != null) {
          builder.add(data);
        }
      }
      final finalBytes = builder.takeBytes();

      setState(() {
        _statusMessage = 'Đang remux sang MP4 (Dart thuần)...';
      });

      Uint8List outputBytes = finalBytes;
      try {
        // Remux MPEG-TS -> MP4 bằng Dart thuần (chạy được cả trên Web).
        outputBytes = remuxTsToMp4(finalBytes);
      } catch (e) {
        // ignore: avoid_print
        print('Lỗi trong quá trình remux: $e');
      }

      // 7. Trigger Browser Download (Wasm-compatible)
      setState(() {
        _statusMessage = 'Đang xuất video về máy...';
      });

      final arrayBuffer = outputBytes.toJS;
      final blob =
          web.Blob([arrayBuffer].toJS, web.BlobPropertyBag(type: 'video/mp4'));
      final downloadUrl = web.URL.createObjectURL(blob);
      final anchor = web.HTMLAnchorElement()
        ..href = downloadUrl
        ..download =
            'lumi_download_${DateTime.now().millisecondsSinceEpoch}.mp4';
      web.document.body!.appendChild(anchor);
      anchor.click();
      web.document.body!.removeChild(anchor);
      web.URL.revokeObjectURL(downloadUrl);

      setState(() {
        _isDownloading = false;
        _progress = 1.0;
        _statusMessage =
            'Tải xuống thành công! Tệp tin đã được lưu về thư mục Downloads.';
      });
    } catch (e) {
      setState(() {
        _isDownloading = false;
        _statusMessage = 'Lỗi: $e';
      });
    }
  }

  /// Trình tải video HLS cho Native (Android, iOS, macOS, Windows)
  Future<void> _startNativeDownload(String url) async {
    setState(() {
      _isDownloading = true;
      _progress = 0.0;
      _downloadedSegs = 0;
      _totalSegs = 0;
      _downloadSpeed = '0.0 KB/s';
      _statusMessage = 'Đang kết nối luồng native...';
    });

    try {
      final taskId = 'video_${DateTime.now().millisecondsSinceEpoch}';

      _activeNativeTask = await HlsDownloader.instance.createDownload(
        taskId: taskId,
        m3u8Url: url,
        fileName: 'lumi_$taskId.mp4',
        downloadMode: HlsDownloadMode.mergeAsSingleFile,
      );

      _activeNativeTask!.progressStream.listen((progress) {
        if (!mounted) return;
        setState(() {
          _progress = progress.percentage / 100;
          _downloadedSegs = progress.downloadedSegments;
          _totalSegs = progress.totalSegments;
          _downloadSpeed =
              '${progress.downloadSpeedKbps.toStringAsFixed(1)} KB/s';
          _statusMessage = 'Đang tải phân đoạn: $_downloadedSegs/$_totalSegs';
        });
      });

      _activeNativeTask!.stateStream.listen((state) {
        if (!mounted) return;
        if (state == HlsDownloadState.success) {
          setState(() {
            _isDownloading = false;
            _progress = 1.0;
            _statusMessage = 'Đã tải thành công và lưu vào thư mục Downloads!';
          });
        }
      });

      await _activeNativeTask!.start();
    } catch (e) {
      setState(() {
        _isDownloading = false;
        _statusMessage = 'Lỗi Native: $e';
      });
    }
  }

  void _triggerDownload() {
    final url = _urlController.text.trim();
    if (url.isEmpty || !url.startsWith('http')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Vui lòng cung cấp link m3u8 hợp lệ bắt đầu với http/https')),
      );
      return;
    }

    if (kIsWeb) {
      _startWebDownload(url);
    } else {
      _startNativeDownload(url);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Background Gradient trang nhã nghệ thuật
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Color(0xFF0F0B1E),
                    Color(0xFF1B0E3C),
                    Color(0xFF0D0A24),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
            ),
          ),

          // Các đốm sáng glowing bay lơ lửng tạo chiều sâu
          Positioned(
            top: -100,
            left: -100,
            child: AnimatedBuilder(
              animation: _glowController,
              builder: (context, child) {
                return Container(
                  width: 300 + (_glowController.value * 50),
                  height: 300 + (_glowController.value * 50),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.deepPurpleAccent.withOpacity(0.15),
                        blurRadius: 100,
                        spreadRadius: 30,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),

          Positioned(
            bottom: -50,
            right: -50,
            child: AnimatedBuilder(
              animation: _glowController,
              builder: (context, child) {
                return Container(
                  width: 250 + (_glowController.value * 40),
                  height: 250 + (_glowController.value * 40),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.pinkAccent.withOpacity(0.1),
                        blurRadius: 90,
                        spreadRadius: 20,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),

          // Nội dung chính nằm giữa màn hình
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 650),
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E193C).withOpacity(0.7),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.08),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.4),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    )
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Header Logo
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.deepPurpleAccent.withOpacity(0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.video_library,
                        size: 40,
                        color: Colors.deepPurpleAccent,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Lumi HLS Downloader',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.0,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Tải xuống video phân đoạn HLS đa nền tảng',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.white.withOpacity(0.6),
                      ),
                    ),
                    const SizedBox(height: 32),

                    // Input Field (Glassmorphic Style)
                    TextField(
                      controller: _urlController,
                      enabled: !_isDownloading,
                      decoration: InputDecoration(
                        labelText: 'Đường dẫn file HLS (.m3u8)',
                        labelStyle:
                            TextStyle(color: Colors.white.withOpacity(0.7)),
                        hintText: 'Nhập link https://...',
                        prefixIcon: const Icon(Icons.link,
                            color: Colors.deepPurpleAccent),
                        filled: true,
                        fillColor: const Color(0xFF0F0B1E).withOpacity(0.5),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide:
                              BorderSide(color: Colors.white.withOpacity(0.1)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: const BorderSide(
                              color: Colors.deepPurpleAccent, width: 2),
                        ),
                        disabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide:
                              BorderSide(color: Colors.white.withOpacity(0.05)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Quick select presets
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'Mẫu thử:',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white.withOpacity(0.5),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ActionChip(
                          avatar: const Icon(Icons.movie, size: 14, color: Colors.blueAccent),
                          label: const Text('BipBop H.264'),
                          backgroundColor: Colors.blueAccent.withOpacity(0.1),
                          side: BorderSide(color: Colors.blueAccent.withOpacity(0.3)),
                          onPressed: () {
                            _urlController.text = 'https://playertest.longtailvideo.com/adaptive/bipbop/gear1/prog_index.m3u8';
                          },
                        ),
                        const SizedBox(width: 8),
                        ActionChip(
                          avatar: const Icon(Icons.videocam, size: 14, color: Colors.pinkAccent),
                          label: const Text('Camera H.265'),
                          backgroundColor: Colors.pinkAccent.withOpacity(0.1),
                          side: BorderSide(color: Colors.pinkAccent.withOpacity(0.3)),
                          onPressed: () {
                            _urlController.text = 'https://your-h265-camera-stream-url.com/stream.m3u8';
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // Progress Panel (Show only when downloading, complete, or failed with error)
                    if (_isDownloading || _progress > 0 || _statusMessage.contains('Lỗi')) ...[
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F0B1E).withOpacity(0.4),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Text(
                                    _statusMessage,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                      color: _statusMessage.contains('Lỗi')
                                          ? Colors.redAccent
                                          : Colors.white,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Text(
                                  '${(_progress * 100).toStringAsFixed(1)}%',
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.pinkAccent,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: LinearProgressIndicator(
                                value: _progress,
                                minHeight: 8,
                                backgroundColor: Colors.white.withOpacity(0.05),
                                valueColor: const AlwaysStoppedAnimation<Color>(
                                    Colors.deepPurpleAccent),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Phân mảnh: $_downloadedSegs / $_totalSegs',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.white.withOpacity(0.5)),
                                ),
                                Text(
                                  'Tốc độ: $_downloadSpeed',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.white.withOpacity(0.5)),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],

                    // Action Button (Glowing)
                    Container(
                      width: double.infinity,
                      height: 54,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          if (!_isDownloading)
                            BoxShadow(
                              color: Colors.deepPurpleAccent.withOpacity(0.3),
                              blurRadius: 15,
                              offset: const Offset(0, 5),
                            )
                        ],
                      ),
                      child: ElevatedButton(
                        onPressed: _isDownloading ? null : _triggerDownload,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.deepPurpleAccent,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor:
                              Colors.deepPurpleAccent.withOpacity(0.3),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          elevation: 0,
                        ),
                        child: _isDownloading
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.white),
                                ),
                              )
                            : const Text(
                                'Bắt đầu Tải xuống',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Platform badge
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        'Đang chạy trên: ${kIsWeb ? "Web Browser" : Platform.operatingSystem.toUpperCase()}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.white.withOpacity(0.5),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
