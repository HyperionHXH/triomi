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

  TtsUtterance? get current => spoken.isEmpty ? null : spoken.last;

  Future<void> completeCurrent() async {
    final currentUtterance = current;
    if (currentUtterance == null) return;
    _callbacks?.onComplete?.call(currentUtterance.text);
    await Future<void>.delayed(Duration.zero);
  }

  void failCurrent(String message) {
    _callbacks?.onError?.call(StateError(message));
  }

  @override
  Future<void> speak(TtsUtterance utterance) async => spoken.add(utterance);

  @override
  Future<bool> pause() async {
    pauseCalled = true;
    return supportsPause;
  }

  @override
  Future<void> resume() async => resumeCalled = true;

  @override
  Future<void> stop() async => stopCalled += 1;

  @override
  Future<void> applySpeechSettings({double? rate, TtsVoiceInfo? voice}) async {}

  @override
  Future<List<TtsVoiceInfo>> availableVoices() async =>
      const <TtsVoiceInfo>[];
}
