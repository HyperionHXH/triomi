import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/features/player/data/native_video_state_machine.dart';

void main() {
  group('NativeVideoStateMachine', () {
    test('prepared auto-starts and pause/resume preserves position', () {
      final machine = NativeVideoStateMachine()..setUrl('https://x/video.mp4');
      machine.onPrepared(30_023);
      expect(machine.state.phase, NativeVideoPhase.playing);
      machine.onPosition(2_000);
      machine.pause();
      expect(machine.state, isA<NativeVideoState>());
      expect(machine.state.positionMs, 2_000);
      expect(machine.state.shouldPlay, isFalse);
      machine.play();
      expect(machine.state.phase, NativeVideoPhase.playing);
    });

    test('surface rebuild keeps position and play intent', () {
      final machine = NativeVideoStateMachine()..setUrl('https://x/video.mp4');
      machine.onPrepared(30_023);
      machine.onPosition(4_500);
      machine.onSurfaceDestroyed();
      expect(machine.state.phase, NativeVideoPhase.surfaceDetached);
      expect(machine.state.positionMs, 4_500);
      expect(machine.state.shouldPlay, isTrue);
      machine.onSurfaceAvailable();
      expect(machine.state.phase, NativeVideoPhase.loading);
      machine.onPrepared(30_023);
      expect(machine.state.phase, NativeVideoPhase.playing);
      expect(machine.state.positionMs, 4_500);
    });

    test('completed and error stop playback; changing URL resets them', () {
      final machine = NativeVideoStateMachine()..setUrl('https://x/a.mp4');
      machine.onPrepared(1_000);
      machine.onCompleted();
      expect(machine.state.phase, NativeVideoPhase.completed);
      expect(machine.state.positionMs, 1_000);
      machine.onError('decode failed');
      expect(machine.state.phase, NativeVideoPhase.error);
      expect(machine.state.shouldPlay, isFalse);
      machine.setUrl('https://x/b.mp4');
      expect(machine.state.phase, NativeVideoPhase.loading);
      expect(machine.state.positionMs, 0);
      expect(machine.state.error, isNull);
    });

    test('seek clamps to the known duration', () {
      final machine = NativeVideoStateMachine()..setUrl('https://x/a.mp4');
      machine.onPrepared(1_000);
      machine.seek(2_000);
      expect(machine.state.positionMs, 1_000);
      machine.seek(-10);
      expect(machine.state.positionMs, 0);
    });

    // -------------------------------------------------- G3/D13 对照 Kotlin 补充

    test('暂停后 Surface 重建不自动播放（Kotlin 保存的是 isPlaying 意图）', () {
      final machine = NativeVideoStateMachine()..setUrl('https://x/video.mp4');
      machine.onPrepared(30_023);
      machine.onPosition(4_500);
      machine.pause();
      expect(machine.state.shouldPlay, isFalse);

      machine.onSurfaceDestroyed();
      machine.onSurfaceAvailable();
      expect(machine.state.phase, NativeVideoPhase.loading);
      machine.seek(9_000);
      expect(machine.state.positionMs, 4_500);
      // shouldPlay 已是 false：重建后停在暂停意图上。
      machine.onPrepared(30_023);
      expect(
        machine.state.phase,
        NativeVideoPhase.prepared,
        reason: '暂停后重建不能自动播放',
      );
      expect(machine.state.positionMs, 4_500, reason: '位置在重建后保留');
      expect(machine.state.shouldPlay, isFalse);

      // 用户显式点播放才继续。
      machine.play();
      expect(machine.state.phase, NativeVideoPhase.playing);
    });

    test('duration=0（直播/未知容器）时 seek 不崩也不钳死', () {
      final machine = NativeVideoStateMachine()..setUrl('https://x/live.m3u8');
      machine.onPrepared(0);
      expect(machine.state.phase, NativeVideoPhase.playing);
      expect(machine.state.durationMs, 0);

      // 没有已知时长：上界放开到哨兵值，只做下钳。
      machine.seek(5_000);
      expect(machine.state.positionMs, 5_000);
      machine.seek(-1);
      expect(machine.state.positionMs, 0);
      expect(machine.state.phase, NativeVideoPhase.playing);

      machine.onCompleted();
      expect(machine.state.positionMs, 0);
    });

    test('prepared 之前的 play/pause 只记录意图，onPrepared 才落地', () {
      final machine = NativeVideoStateMachine()..setUrl('https://x/a.mp4');
      // loading 阶段点播放：不能把相位谎报成 prepared/playing。
      machine.play();
      expect(machine.state.phase, NativeVideoPhase.loading);
      expect(machine.state.shouldPlay, isTrue);
      machine.onPrepared(1_000);
      expect(
        machine.state.phase,
        NativeVideoPhase.playing,
        reason: '意图为播放，prepared 后自动开播',
      );

      // loading 阶段点暂停：不自动开播。
      final other = NativeVideoStateMachine()..setUrl('https://x/b.mp4');
      other.pause();
      expect(other.state.phase, NativeVideoPhase.loading);
      expect(other.state.shouldPlay, isFalse);
      other.onPrepared(1_000);
      expect(other.state.phase, NativeVideoPhase.prepared);
    });

    test('prepared 之前的 seek 被忽略（Kotlin: if (prepared) seekTo）', () {
      final machine = NativeVideoStateMachine()..setUrl('https://x/a.mp4');
      machine.seek(500);
      expect(machine.state.positionMs, 0);

      machine.onPrepared(10_000);
      machine.onSurfaceDestroyed();
      machine.seek(700);
      expect(machine.state.positionMs, 0, reason: 'player 已随 Surface 释放');
    });

    test('换线路重置后旧时长不残留（setUrl 清零 position/duration）', () {
      final machine = NativeVideoStateMachine()..setUrl('https://x/long.mp4');
      machine.onPrepared(120_000);
      machine.onPosition(60_000);
      machine.setUrl('https://x/short.mp4');
      expect(machine.state.durationMs, 0);
      expect(machine.state.positionMs, 0);
      // 旧时长不残留：新片 prepared 前 seek 不受旧上界影响（且被忽略）。
      machine.seek(30_000);
      expect(machine.state.positionMs, 0);
      machine.onPrepared(8_000);
      expect(machine.state.durationMs, 8_000);
    });

    test('play during paused surface preparation only updates intent', () {
      final machine = NativeVideoStateMachine()..setUrl('https://x/a.mp4');
      machine.onPrepared(10_000);
      machine.pause();
      machine.onSurfaceDestroyed();
      machine.onSurfaceAvailable();
      machine.play();
      expect(machine.state.phase, NativeVideoPhase.loading);
      expect(machine.state.shouldPlay, isTrue);
      machine.onPrepared(10_000);
      expect(machine.state.phase, NativeVideoPhase.playing);
    });

    test('unknown duration keeps position across surface preparation', () {
      final machine = NativeVideoStateMachine()..setUrl('https://x/live.m3u8');
      machine.onPrepared(0);
      machine.onPosition(5_000);
      machine.onSurfaceDestroyed();
      machine.onSurfaceAvailable();
      machine.onPrepared(0);
      expect(machine.state.positionMs, 5_000);
    });
  });
}
