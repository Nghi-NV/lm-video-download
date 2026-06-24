import 'package:flutter_test/flutter_test.dart';
import 'package:lm_video_download/lm_video_download.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('HlsDownloader instance initialization check', () async {
    final downloader = HlsDownloader.instance;
    expect(downloader, isNotNull);
  });

  test('HlsDownloadProgress model verification', () {
    final progress = HlsDownloadProgress(
      taskId: 'test_task',
      percentage: 50.0,
      downloadedSegments: 5,
      totalSegments: 10,
      bytesDownloaded: 1024,
      downloadSpeedKbps: 256.0,
    );

    expect(progress.taskId, 'test_task');
    expect(progress.percentage, 50.0);
    expect(progress.downloadedSegments, 5);
    expect(progress.totalSegments, 10);
    expect(progress.bytesDownloaded, 1024);
    expect(progress.downloadSpeedKbps, 256.0);
    expect(progress.toString(), contains('50.0%'));
  });
}
