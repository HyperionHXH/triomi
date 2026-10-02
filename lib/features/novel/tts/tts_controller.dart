import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../novel/reader/novel_blocks.dart';

/// TTS 鏈楄浣嶇疆锛氭鍦ㄦ湕璇诲摢涓帓鐗堝潡銆?///
/// 涓庨槄璇诲櫒鐨?`_progressParagraph`锛堝潡涓嬫爣锛夊悓涓€閿氭ā鍨嬶紝涓嶅彂鏄庣浜屽浣嶇疆銆?typedef TtsAnchor = int;

/// 涓€鏉″緟鏈楄鐨勮闊冲崟鍏冿紙D31 鍚堝悓锛氱涓€鐗堟寜銆屾钀姐€嶄负 utterance 绮掑害锛夈€?///
/// - 鎻掑浘鍧椾骇鍑?[isPlaceholder] = true 鐨勫崰浣?utterance锛堟湕璇绘浛鎹㈣瘝锛屽
///   銆屾彃鍥俱€嶏級锛屾湕璇讳細鎵ц锛屼絾**涓嶈鍏ラ槄璇昏繘搴﹂敋**锛堣 [TtsProgress.anchor]锛夛紱
/// - 鍒嗛〉鎶婁竴涓钀藉垏鎴愬椤垫椂锛岃法椤靛彞瀛愬厛鎸夊潡鎷兼帴鍐嶄氦缁欏紩鎿庘€斺€旀湰灞傚彧璁?///   `List<ReaderBlock>`锛屽垎椤垫槸娓叉煋灞傛蹇碉紝涓嶅奖鍝?utterance 鍒掑垎銆?class TtsUtterance {
  const TtsUtterance({
    required this.blockIndex,
    required this.text,
    this.isPlaceholder = false,
    this.pauseAfterMs = 0,
    this.token = 0,
  });

  /// 浜у嚭璇?utterance 鐨勬帓鐗堝潡涓嬫爣锛坄ReaderBlock` 搴忓垪涓殑浣嶇疆锛夈€?  final int blockIndex;

  /// 鏈楄鏂囨湰锛堟爣棰?娈佃惤鍘熸枃锛涙彃鍥惧崰浣嶄负鏇挎崲璇嶏級銆?  final String text;

  /// 鏄惁涓烘彃鍥惧崰浣嶏紙鍗犱綅涓嶆帹杩涢槄璇婚敋锛夈€?  final bool isPlaceholder;

  /// 鏈楄瀹岃鏉″悗鐨勫缓璁仠椤匡紙鏍囬/鎻掑浘鍚庡仠椤匡級銆?  final int pauseAfterMs;
  final int token;
}

/// 鏈楄杩涘害锛氭湕璇讳綅缃?+ 闃呰閿氥€?class TtsProgress {
  const TtsProgress({
    required this.utteranceIndex,
    required this.blockIndex,
    this.anchor,
  });

  /// 褰撳墠 utterance 鍦ㄨ鍒掍腑鐨勪笅鏍囥€?  final int utteranceIndex;

  /// 姝ｅ湪鏈楄鐨勫潡涓嬫爣锛堝崰浣嶆椂涓烘彃鍥惧潡涓嬫爣锛夈€?  final int blockIndex;

  /// 闃呰鍣ㄥ簲鏄剧ず鐨勪綅缃敋锛氭渶杩戜竴涓潪鍗犱綅 utterance 鐨勫潡涓嬫爣锛?  /// 杩樻病璇诲埌浠讳綍鍙鍧楁椂涓?null锛堝崰浣嶄笉鎺ㄨ繘閿氾級銆?  final TtsAnchor? anchor;
}

/// 寮曟搸鍥炶皟锛歶tterance 瀹屾垚 / 鍑洪敊銆?class TtsEngineCallbacks {
  TtsEngineCallbacks({this.onComplete, this.onCompleteWithToken, this.onError});

  /// 褰撳墠 utterance 鑷劧鎾畬锛坱ext 鐢ㄤ簬鏍″褰掑睘锛夈€?  final void Function(String text)? onComplete;

  /// Preferred completion callback. [token] is issued for each speak call and
  /// lets the controller discard a late callback after seek/stop.
  final void Function(String text, int token)? onCompleteWithToken;

  /// 寮曟搸灞傞敊璇紙鍚堟垚澶辫触銆佸紩鎿庝笉鍙敤绛夛級銆?  final void Function(Object error)? onError;
}

/// 绯荤粺闊宠壊锛圖48锛夛細鍚嶇О + 璇█鍖哄煙锛屼粎鏉ヨ嚜寮曟搸瀹為檯杩斿洖鐨勫彲鐢ㄩ」銆?class TtsVoiceInfo {
  const TtsVoiceInfo({required this.name, required this.locale});

  final String name;
  final String locale;

  String get label => '$name锛?locale锛?;

  @override
  bool operator ==(Object other) =>
      other is TtsVoiceInfo && other.name == name && other.locale == locale;

  @override
  int get hashCode => Object.hash(name, locale);
}

/// TTS 寮曟搸鎶借薄锛圖31 鍚堝悓锛夛細鎻掍欢瀹炵幇鐢?Codex 鎻愪緵锛圖37 flutter_tts 鎺ョ嚎锛夛紝
/// 鏈眰涓庢祴璇曞彧渚濊禆鎺ュ彛銆?///
/// 濂戠害锛?/// - [speak] 杩斿洖鍗宠〃绀哄紩鎿庡凡鍙楃悊锛涘畬鎴愮敱 [callbacks] 鐨?onComplete 閫氱煡锛?/// - [pause] 骞冲彴宸紓澶э紙Android 闇€瑕?workaround銆乄indows 鏃?speech marks锛夛紝
///   杩斿洖 false 琛ㄧず骞冲彴涓嶆敮鎸佲€斺€旀帶鍒跺櫒鎸夈€屽仠姝㈠綋鍓嶆銆佹仮澶嶆椂閲嶈銆嶉檷绾э紱
/// - [stop] 蹇呴』骞傜瓑銆?abstract class TtsEngine {
  bool get supportsPause;

  /// 寮曟搸鎶婂畬鎴?閿欒鍥炶皟鎶ュ埌杩欓噷锛堟帶鍒跺櫒鏋勯€犳椂娉ㄥ叆锛夈€?  set callbacks(TtsEngineCallbacks value);

  Future<void> speak(TtsUtterance utterance);

  /// @return 骞冲彴鏄惁鐪熸鏀寔鏆傚仠锛坒alse 鈫?璋冪敤鏂规寜鍋滄-閲嶈闄嶇骇锛夈€?  Future<bool> pause();

  Future<void> resume();

  Future<void> stop();

  /// 璇煶閫夐」锛圖48锛夛細浼氳瘽寮€濮嬪墠搴旂敤涓€娆°€傞粯璁ゅ疄鐜颁负銆屾棤閫夐」銆嶏紝渚?  /// 娴嬭瘯鏇胯韩涓庝笉鏀寔闊宠壊/璇€熺殑骞冲彴鐩存帴澶嶇敤锛涚湡瀹炲紩鎿庢寜闇€瑕嗙洊銆?  Future<void> applySpeechSettings({double? rate, TtsVoiceInfo? voice}) async {}

  /// 绯荤粺鍙敤闊宠壊鍒楄〃锛圖48锛夈€傞粯璁よ繑鍥炵┖ = 骞冲彴鏈彁渚涙垨鏌ヨ涓嶅彲鐢紝
  /// 璋冪敤鏂规寜銆岀郴缁熼粯璁ら煶鑹层€嶉檷绾э紝涓嶄吉閫犻€夐」銆?  Future<List<TtsVoiceInfo>> availableVoices() async =>
      const <TtsVoiceInfo>[];
}

/// TTS 浼氳瘽鐘舵€併€?enum TtsState { idle, playing, paused, completed, error }

/// 鏈楄璁″垝锛歶tterance 搴忓垪锛堢函鍑芥暟浜у嚭锛屽彲鐙珛娴嬭瘯锛夈€?class TtsPlan {
  const TtsPlan({required this.utterances});

  final List<TtsUtterance> utterances;

  static const String illustrationPlaceholder = '鎻掑浘';

  /// 鎶婃帓鐗堝潡瑙勫垝鎴?utterance 搴忓垪锛?  /// - 鏍囬/娈佃惤 鈫?鍘熸枃锛屾爣棰樺悗鍋滈】 [headingPauseMs]锛?  /// - 鎻掑浘 鈫?鍗犱綅璇嶏紙鍗犱綅涓嶈鍏ラ槄璇婚敋锛夛紱
  /// - 绌虹櫧鏂囨湰娈佃惤璺宠繃锛堥槻寰℃€у鐞嗭級銆?  static TtsPlan of(
    List<ReaderBlock> blocks, {
    String illustrationText = illustrationPlaceholder,
    int headingPauseMs = 240,
    int illustrationPauseMs = 360,
    int maxCharacters = 1800,
  }) {
    final utterances = <TtsUtterance>[];
    final limit = maxCharacters.clamp(1, 10000);
    void addText(int blockIndex, String text, {int pauseAfterMs = 0}) {
      final chunks = _splitText(text, limit);
      for (var i = 0; i < chunks.length; i++) {
        utterances.add(
          TtsUtterance(
            blockIndex: blockIndex,
            text: chunks[i],
            pauseAfterMs: i == chunks.length - 1 ? pauseAfterMs : 0,
          ),
        );
      }
    }
    for (var index = 0; index < blocks.length; index++) {
      final block = blocks[index];
      switch (block) {
        case HeadingBlock(:final text):
          if (text.trim().isEmpty) continue;
          addText(index, text, pauseAfterMs: headingPauseMs);
        case ParagraphBlock(:final text):
          if (text.trim().isEmpty) continue;
          addText(index, text);
        case IllustrationBlock():
          utterances.add(
            TtsUtterance(
              blockIndex: index,
              text: illustrationText,
              isPlaceholder: true,
              pauseAfterMs: illustrationPauseMs,
            ),
          );
      }
    }
    return TtsPlan(utterances: utterances);
  }

  /// Keep every engine request below the platform input limit.  A split keeps
  /// the original block index, so progress remains anchored to the same
  /// rendered paragraph even when a paragraph spans several utterances.
  static List<String> _splitText(String text, int limit) {
    final value = text.trim();
    if (value.length <= limit) return <String>[value];
    final result = <String>[];
    var start = 0;
    while (start < value.length) {
      final remaining = value.length - start;
      if (remaining <= limit) {
        result.add(value.substring(start).trim());
        break;
      }
      var end = start + limit;
      final window = value.substring(start, end);
      final breakAt = window.lastIndexOf(RegExp(r'[\n\r\t 锛屻€傦紒锛燂紱锛氥€?.!?;:)]'));
      if (breakAt > limit ~/ 2) end = start + breakAt + 1;
      final chunk = value.substring(start, end).trim();
      if (chunk.isNotEmpty) result.add(chunk);
      start = end;
      while (start < value.length && value[start].trim().isEmpty) {`r`n        start++;`r`n      }
    }
    return result;
  }
}

/// TTS 鎺у埗鍣紙D31 鍚堝悓 + 绾?Dart seam锛夈€?///
/// 鑱岃矗锛?/// - 鎸佹湁 [TtsPlan]锛屾寜搴忛┍鍔?[TtsEngine]锛?/// - 缁存姢 [state] 涓?[progress]锛堟湕璇讳綅缃?+ 闃呰閿氾級锛?/// - 閿佸畾绔?*鎷掔粷鏈楄**锛坄start` 鎶涢敊銆佸紩鎿庨浂璋冪敤鈥斺€斻€屼笉瑙ｉ攣涓嶇紦瀛樸€嶇孩绾?///   鍦ㄦ湕璇诲煙鐨勯暅鍍忥級锛?/// - 寮曟搸瀹屾垚鍥炶皟椹卞姩鎺ㄨ繘锛涢敊璇繘鍏?[TtsState.error]锛?/// - 骞冲彴涓嶆敮鎸佹殏鍋滄椂鎸夈€屽仠姝㈠綋鍓嶆銆佹仮澶嶉噸璇汇€嶉檷绾э紙绗竴鐗堝熀绾匡級銆?///
/// 涓嶅惈鎻掍欢銆侀煶棰戠劍鐐广€佸墠鍙版湇鍔′笌闃呰鍣ㄦ帴绾匡紙Codex 鑷暀 D37 鑼冨洿锛夈€?class TtsController extends ChangeNotifier {
  TtsController({required this._engine, required List<ReaderBlock> blocks})
    : _plan = TtsPlan.of(blocks) {
    _engine.callbacks = TtsEngineCallbacks(
      onComplete: _onUtteranceComplete,
      onCompleteWithToken: _onUtteranceCompleteWithToken,
      onError: _onUtteranceError,
    );
  }

  final TtsEngine _engine;
  final TtsPlan _plan;

  TtsState _state = TtsState.idle;
  int _utteranceIndex = -1;

  /// 闃呰閿氾細鏈€杩戜竴涓潪鍗犱綅 utterance 鐨勫潡涓嬫爣銆?  TtsAnchor? _anchor;

  /// 鏄惁澶勪簬銆岄檷绾ф殏鍋溿€嶏紙寮曟搸涓嶆敮鎸?pause锛屾仮澶嶆椂闇€瑕侀噸璇诲綋鍓嶆锛夈€?  bool _degradedPause = false;
  int _speakToken = 0;
  int _activeSpeakToken = 0;

  TtsState get state => _state;
  TtsPlan get plan => _plan;
  int get utteranceIndex => _utteranceIndex;

  /// 褰撳墠鏈楄杩涘害锛坕dle/completed/error 涓旀湭寮€濮嬫椂涓?null锛夈€?  TtsProgress? get progress {
    if (_utteranceIndex < 0 || _utteranceIndex >= _plan.utterances.length) {
      return null;
    }
    final utterance = _plan.utterances[_utteranceIndex];
    return TtsProgress(
      utteranceIndex: _utteranceIndex,
      blockIndex: utterance.blockIndex,
      anchor: _anchor,
    );
  }

  /// 寮曟搸鏄惁鏀寔鏆傚仠锛堥€忎紶锛屼緵 UI 鍐冲畾鎸夐挳褰㈡€侊級銆?  bool get supportsPause => _engine.supportsPause;

  /// 寮€濮嬫湕璇汇€傞攣瀹氱珷鐩存帴鎷掔粷锛堝紩鎿庨浂璋冪敤锛岀姸鎬佺疆 error锛夈€?  Future<void> start({required bool locked}) async {
    if (_state == TtsState.playing || _state == TtsState.paused) return;
    if (locked) {
      _state = TtsState.error;
      throw StateError('閿佸畾绔犺妭涓嶆彁渚涙湕璇?);
    }
    if (_plan.utterances.isEmpty) {
      _state = TtsState.completed;
      return;
    }
    _state = TtsState.playing;
    _utteranceIndex = 0;
    _anchor = null;
    await _speakCurrent();
  }

  Future<void> _speakCurrent() async {
    final token = ++_speakToken;
    _activeSpeakToken = token;
    final utterance = _plan.utterances[_utteranceIndex];
    if (!utterance.isPlaceholder) {
      _anchor = utterance.blockIndex;
    }
    notifyListeners();
    try {
      await _engine.speak(
        TtsUtterance(
          blockIndex: utterance.blockIndex,
          text: utterance.text,
          isPlaceholder: utterance.isPlaceholder,
          pauseAfterMs: utterance.pauseAfterMs,
          token: token,
        ),
      );
    } catch (error) {
      if (token == _activeSpeakToken && _state == TtsState.playing) {
        _onUtteranceError(error);
      }
    }
  }

  /// 鏆傚仠锛氬紩鎿庝笉鏀寔鏃堕檷绾т负銆屽仠姝㈠綋鍓嶆锛屾仮澶嶆椂閲嶈銆嶃€?  Future<void> pause() async {
    if (_state != TtsState.playing) return;
    _state = TtsState.paused;
    notifyListeners();
    final supported = await _engine.pause();
    _degradedPause = !supported;
    if (!supported) await _engine.stop();
  }

  Future<void> resume() async {
    if (_state != TtsState.paused) return;
    _state = TtsState.playing;
    if (_degradedPause) {
      _degradedPause = false;
      await _speakCurrent(); // 涓嶆敮鎸佹殏鍋滅殑骞冲彴锛氶噸璇诲綋鍓嶆銆?      return;
    }
    await _engine.resume();
  }

  /// 鍋滄锛氬洖鍒?idle锛岃繘搴︽竻闆躲€?  Future<void> stop() async {
    if (_state == TtsState.idle) return;
    _activeSpeakToken = -1;
    _state = TtsState.idle;
    _utteranceIndex = -1;
    _anchor = null;
    _degradedPause = false;
    notifyListeners();
    await _engine.stop();
  }

  /// 璺冲埌鎸囧畾 utterance锛圲I 鐐归€夋钀?涓婁竴娈?涓嬩竴娈电敤锛夈€?  Future<void> seekToUtterance(int index) async {
    if (index < 0 || index >= _plan.utterances.length) return;
    _activeSpeakToken = -1;
    _state = TtsState.paused;
    await _engine.stop();
    _utteranceIndex = index;
    _state = TtsState.playing;
    await _speakCurrent();
  }

  void _onUtteranceComplete(String text) {
    _onUtteranceCompleteInternal(text, null);
  }

  void _onUtteranceCompleteWithToken(String text, int token) {
    _onUtteranceCompleteInternal(text, token);
  }

  void _onUtteranceCompleteInternal(String text, int? token) {
    if (_state != TtsState.playing) return;
    if (token != null && token != _activeSpeakToken) return;
    final current = _plan.utterances[_utteranceIndex];
    if (current.text != text) return; // 杩熷埌鐨勬棫鍥炶皟锛氫涪寮冦€?    if (_utteranceIndex + 1 >= _plan.utterances.length) {
      _state = TtsState.completed;
      notifyListeners();
      return;
    }
    _utteranceIndex += 1;
    unawaited(_speakCurrent());
  }

  void _onUtteranceError(Object error) {
    _state = TtsState.error;
    notifyListeners();
  }

  @override
  void dispose() {
    _state = TtsState.idle;
    _activeSpeakToken = -1;
    _engine.callbacks = TtsEngineCallbacks();
    unawaited(_engine.stop().catchError((Object _) {}));
    super.dispose();
  }
}

