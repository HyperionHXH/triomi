import '../source/http_client.dart';

/// Work completed by the real backup pipeline; totals are zero when unknown.
class BackupProgress {
  const BackupProgress(
    this.stage, {
    this.completedBytes = 0,
    this.totalBytes = 0,
    this.completedItems = 0,
    this.totalItems = 0,
  });
  final BackupStage stage;
  final int completedBytes;
  final int totalBytes;
  final int completedItems;
  final int totalItems;
}

enum BackupStage {
  collecting,
  covers,
  media,
  encoding,
  packing,
  uploading,
  verifying,
  publishing,
}

typedef BackupProgressCallback = void Function(BackupProgress progress);

class BackupCancelledException implements Exception {
  const BackupCancelledException();
  @override
  String toString() => '备份已取消；未发布未完成的版本';
}

void checkBackupCancellation() {
  if (SourceRequestCancellation.current?.cancelled == true) {
    throw const BackupCancelledException();
  }
}
