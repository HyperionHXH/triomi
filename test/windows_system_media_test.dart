import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/features/player/data/windows_system_media.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('triomi/windows-media');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final sessions = <WindowsSystemMediaSession>[];
  final calls = <MethodCall>[];

  Future<void> publish(
    WindowsSystemMediaSession session, {
    bool enabled = true,
    bool canNext = true,
    bool canPrevious = true,
  }) => session.update(
    enabled: enabled,
    state: 'playing',
    title: 'Series · Episode 2',
    artist: 'Series',
    canNext: canNext,
    canPrevious: canPrevious,
  );

  Future<void> button(String owner, String command) async {
    final response = Completer<void>();
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('command', {'owner': owner, 'command': command}),
      ),
      (_) => response.complete(),
    );
    await response.future;
  }

  String latestOwner() => (calls.last.arguments as Map)['owner'] as String;

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    for (final session in sessions) {
      session.dispose();
    }
    sessions.clear();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'publishes metadata and routes explicit buttons to the current player',
    () async {
      final commands = <String>[];
      final session = WindowsSystemMediaSession(
        onCommand: (command) async => commands.add(command),
      );
      sessions.add(session);
      await publish(session);
      final owner = latestOwner();
      expect(calls.single.method, 'update');
      expect(calls.single.arguments, {
        'owner': owner,
        'enabled': true,
        'state': 'playing',
        'title': 'Series · Episode 2',
        'artist': 'Series',
        'canNext': true,
        'canPrevious': true,
      });
      for (final command in ['play', 'pause', 'stop', 'next', 'previous']) {
        await button(owner, command);
      }
      expect(commands, ['play', 'pause', 'stop', 'next', 'previous']);
    },
  );

  test(
    'replaced page cannot clear or update its successor or receive buttons',
    () async {
      final oldCommands = <String>[];
      final newCommands = <String>[];
      final old = WindowsSystemMediaSession(
        onCommand: (command) async => oldCommands.add(command),
      );
      sessions.add(old);
      await publish(old);
      final oldOwner = latestOwner();
      final current = WindowsSystemMediaSession(
        onCommand: (command) async => newCommands.add(command),
      );
      sessions.add(current);
      await publish(current);
      final currentOwner = latestOwner();
      expect(currentOwner, isNot(oldOwner));
      expect(calls[1].method, 'clear');
      expect(calls[1].arguments, {'owner': oldOwner});
      final count = calls.length;
      old.dispose();
      old.replace();
      await publish(old);
      expect(calls, hasLength(count));
      await button(oldOwner, 'pause');
      await button(currentOwner, 'play');
      expect(oldCommands, isEmpty);
      expect(newCommands, ['play']);
      current.dispose();
      expect(calls, hasLength(count + 1));
      expect(calls.last.method, 'clear');
      expect(calls.last.arguments, {'owner': currentOwner});
      await publish(old);
      expect(calls, hasLength(count + 1));
    },
  );

  test(
    'returning from nested players restores the latest surviving owner state',
    () async {
      final firstCommands = <String>[];
      final secondCommands = <String>[];
      final thirdCommands = <String>[];
      final first = WindowsSystemMediaSession(
        onCommand: (command) async => firstCommands.add(command),
      );
      sessions.add(first);
      await publish(first);
      final firstOldOwner = latestOwner();
      final second = WindowsSystemMediaSession(
        onCommand: (command) async => secondCommands.add(command),
      );
      sessions.add(second);
      await publish(second);
      final secondOldOwner = latestOwner();
      final count = calls.length;
      await first.update(
        enabled: true,
        state: 'paused',
        title: 'Series · Episode 3',
        artist: 'Series',
        canNext: false,
        canPrevious: true,
      );
      expect(calls, hasLength(count));
      await button(firstOldOwner, 'pause');
      final third = WindowsSystemMediaSession(
        onCommand: (command) async => thirdCommands.add(command),
      );
      sessions.add(third);
      await publish(third);
      final thirdOwner = latestOwner();
      third.dispose();
      final secondOwner = latestOwner();
      expect(calls.last.method, 'update');
      expect(secondOwner, isNot(secondOldOwner));
      await button(thirdOwner, 'play');
      await button(secondOldOwner, 'pause');
      await button(secondOwner, 'pause');
      second.dispose();
      final firstOwner = latestOwner();
      expect(firstOwner, isNot(firstOldOwner));
      expect(calls.last.arguments, {
        'owner': firstOwner,
        'enabled': true,
        'state': 'paused',
        'title': 'Series · Episode 3',
        'artist': 'Series',
        'canNext': false,
        'canPrevious': true,
      });
      await button(secondOwner, 'play');
      await button(firstOldOwner, 'play');
      await button(firstOwner, 'next');
      await button(firstOwner, 'play');
      expect(firstCommands, ['play']);
      expect(secondCommands, ['pause']);
      expect(thirdCommands, isEmpty);
    },
  );

  test(
    'episode replacement rejects queued buttons from the previous episode',
    () async {
      final commands = <String>[];
      final session = WindowsSystemMediaSession(
        onCommand: (command) async => commands.add(command),
      );
      sessions.add(session);
      await publish(session);
      final oldOwner = latestOwner();
      session.replace();
      await button(oldOwner, 'next');
      await publish(session);
      final owner = latestOwner();
      expect(owner, isNot(oldOwner));
      await button(oldOwner, 'pause');
      await button(owner, 'pause');
      expect(commands, ['pause']);
      session.dispose();
      expect(calls.last.method, 'clear');
      expect(calls.last.arguments, {'owner': owner});
      final count = calls.length;
      await publish(session);
      expect(calls, hasLength(count));
    },
  );

  test(
    'disabled transport and unavailable adjacent episodes reject commands',
    () async {
      final commands = <String>[];
      final session = WindowsSystemMediaSession(
        onCommand: (command) async => commands.add(command),
      );
      sessions.add(session);
      await publish(session, canNext: false, canPrevious: false);
      final owner = latestOwner();
      await button(owner, 'next');
      await button(owner, 'previous');
      await button(owner, 'toggle');
      await button(owner, 'pause');
      await publish(session, enabled: false);
      await button(owner, 'play');
      expect(commands, ['pause']);
    },
  );
}
