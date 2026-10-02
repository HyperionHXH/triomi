import 'package:triomi/features/novel/reader/novel_blocks.dart';
import 'package:triomi/features/novel/tts/tts_controller.dart';

class FakeTtsEngine implements TtsEngine {
  FakeTtsEngine({this.supportsPause = true});

  @override
  bool supportsPause;

  @override
  set callbacks(TtsEngineCallbacks value) => _callbacks = value;

  TtsEngineCallbacks? _callbacks;

  final List<TtsUtterance> spoken = <TtsUtterance>[];
  bool pauseCalled = false;
  bool resumeCalled = false;
  int stopCalled = 0;

  /// 当前在朗读的 utterance（最后一�?speak 的）�?  TtsUtterance? get current => spoken.isEmpty ? null : spoken.last;

  /// 模拟引擎播完当前 utterance�?  Future<void> completeCurrent() async {
    final current = this.current;
    if (current == null) return;
    _callbacks?.onComplete?.call(current.text);
    // onComplete 里控制器同步推进并调用下一�?speak（异步），让出事件循环�?    await Future<void>.delayed(Duration.zero);
  }

  /// 模拟引擎错误�?  void failCurrent(String message) {
    _callbacks?.onError?.call(StateError(message));
  }

  @override
  Future<void> speak(TtsUtterance utterance) async {
    spoken.add(utterance);
  }

  @override
  Future<bool> pause() async {
    pauseCalled = true;
    return supportsPause;
  }

  @override
  Future<void> resume() async {
    resumeCalled = true;
  }

  @override
  Future<void> stop() async {
    stopCalled += 1;
  }

  // D48 语音选项：合同层默认实现为空，这里显式落地以保持 implements 完整�?  // 需要记录语�?音色的替身见 d48_tts_settings_test.dart �?_VoiceEngine�?  @override
  Future<void> applySpeechSettings({double? rate, TtsVoiceInfo? voice}) async {}

  @override
  Future<List<TtsVoiceInfo>> availableVoices() async => const <TtsVoiceInfo>[];
}

