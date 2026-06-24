// ignore_for_file: avoid_print
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lm_video_download/lm_video_download.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Apple BipBop HLS download and remux to MP4 container integration test', () async {
    HttpOverrides.global = null;

    // Giả lập path_provider trong môi trường kiểm thử
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async {
        return './test_download_output_remux/temp';
      },
    );

    print('=== BẮT ĐẦU KIỂM CHỨNG TẢI & REMUX VIDEO HLS SANG MP4 ===');

    const m3u8Url = 'https://playertest.longtailvideo.com/adaptive/bipbop/gear1/prog_index.m3u8';
    final outputDir = Directory('./test_download_output_remux');
    
    if (await outputDir.exists()) {
      await outputDir.delete(recursive: true);
    }
    await outputDir.create(recursive: true);

    print('Khởi tạo Downloader...');
    await HlsDownloader.instance.initialize(
      customStoragePath: outputDir.absolute.path,
      maxConcurrentDownloads: 5,
      enableLogging: true,
    );

    print('Đang tạo tác vụ tải từ URL: $m3u8Url');
    final task = await HlsDownloader.instance.createDownload(
      taskId: 'bipbop_remux_test',
      m3u8Url: m3u8Url,
      fileName: 'bipbop_output.mp4',
      downloadMode: HlsDownloadMode.mergeAsSingleFile,
    );

    task.progressStream.listen((progress) {
      print('Tiến độ: ${progress.percentage.toStringAsFixed(1)}% '
          '(${progress.downloadedSegments}/${progress.totalSegments} segments) '
          '- Tốc độ: ${progress.downloadSpeedKbps.toStringAsFixed(1)} KB/s');
    });

    task.stateStream.listen((state) {
      print('>>> Trạng thái: $state');
    });

    print('Bắt đầu tải và remux...');
    final stopwatch = Stopwatch()..start();
    await task.start();
    stopwatch.stop();

    print('\n=== KẾT QUẢ TẢI & REMUX ===');
    print('Thời gian: ${stopwatch.elapsed.inSeconds} giây');

    final outputFile = File('${outputDir.path}/bipbop_output.mp4');
    expect(await outputFile.exists(), isTrue);

    final length = await outputFile.length();
    print('Tệp tin video: ${outputFile.path}');
    print('Kích thước: ${(length / (1024 * 1024)).toStringAsFixed(2)} MB');
    expect(length, greaterThan(0));

    // Đọc byte đầu tiên của file để xác định xem có đúng là cấu trúc MP4 không (ftyp box)
    final fileBytes = await outputFile.readAsBytes();
    expect(fileBytes.length, greaterThan(8));
    final containerType = String.fromCharCodes(fileBytes.sublist(4, 8));
    print('Magic type tại offset 4: $containerType');
    expect(containerType, equals('ftyp'), reason: 'File container should be MP4 (ftyp box)');

    await task.delete();
    if (await outputDir.exists()) {
      await outputDir.delete(recursive: true);
    }

    print('=== KIỂM CHỨNG REMUX HOÀN TẤT THÀNH CÔNG ===');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
