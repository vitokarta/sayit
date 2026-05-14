import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'models.dart';

const _apiBase    = 'https://sayit-us.onrender.com';
const _apiSecret  = String.fromEnvironment('API_SECRET', defaultValue: '');
const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5];

Map<String, String> get _authHeaders => {
  'Content-Type': 'application/json',
  if (_apiSecret.isNotEmpty) 'X-Api-Secret': _apiSecret,
};

enum _Phase { idle, prompting, ready, recording, evaluating, done }
enum _Mode { listen, practice, summary }

class PlayerScreen extends StatefulWidget {
  final Video video;
  const PlayerScreen({super.key, required this.video});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  // ── audio ──────────────────────────────────────────────────────────────────
  final _player = AudioPlayer();
  int _segIdx = 0;
  int _activeIdx = -1;
  double _speed = 1.0;
  StreamSubscription? _posSub;
  StreamSubscription? _stateSub;
  final _scrollController = ScrollController();
  final List<GlobalKey> _keys = [];
  final _listKey = GlobalKey();

  // ── mode ───────────────────────────────────────────────────────────────────
  _Mode _mode = _Mode.listen;
  bool get _practiceMode => _mode == _Mode.practice;
  final _speech = SpeechToText();
  final _tts = FlutterTts();
  bool _speechReady = false;
  _Phase _phase = _Phase.idle;
  int _practiceSeg = 0;
  String _transcript = '';
  Map<String, dynamic>? _feedback;
  String? _feedbackError;
  bool _feedbackPending = false;
  final Set<int> _expandedCorrections = {};

  @override
  void initState() {
    super.initState();
    // 只需要和最長段落等長的 keys（所有段落共用，切換段落時 Flutter 會重新對應）
    final maxLen = widget.video.segments
        .map((s) => s.sentences.length)
        .reduce((a, b) => a > b ? a : b);
    for (var i = 0; i < maxLen; i++) {
      _keys.add(GlobalKey());
    }
    _initSpeechAndTts();
    _playSegment(0);
  }

  Future<void> _initSpeechAndTts() async {
    _speechReady = await _speech.initialize(onError: (_) {});
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.85);
    _tts.setCompletionHandler(() {
      if (mounted && _phase == _Phase.prompting) {
        setState(() => _phase = _Phase.ready);
      }
    });
  }


  Future<void> _playSegment(int idx, {Duration? seekTo}) async {
    if (idx >= widget.video.segments.length) return;
    _posSub?.cancel();   // 立即取消，避免舊 stream 覆蓋 _activeIdx
    _posSub = null;
    setState(() => _segIdx = idx);
    final seg = widget.video.segments[idx];
    await _player.setUrl(seg.audioUrl);
    await _player.setSpeed(_speed);
    if (seekTo != null) await _player.seek(seekTo);
    _posSub = _player.positionStream.listen((pos) {
      final secs = pos.inMilliseconds / 1000.0;
      final sents = seg.sentences;
      int active = 0;
      for (var i = 0; i < sents.length; i++) {
        if (secs >= sents[i].ttsStart) active = i;
      }
      if (active != _activeIdx) {
        setState(() => _activeIdx = active);
        _scrollToActive(active);
      }
    });

    _stateSub?.cancel();   // 同上，提前取消避免舊的觸發 _playSegment
    _stateSub = _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        _playSegment(idx + 1);
      }
    });

    await _player.play();
  }

  void _scrollToActive(int idx) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final itemCtx = _keys[idx].currentContext;
      final listCtx = _listKey.currentContext;
      if (itemCtx == null || listCtx == null) return;
      final itemBox = itemCtx.findRenderObject() as RenderBox?;
      final listBox = listCtx.findRenderObject() as RenderBox?;
      if (itemBox == null || listBox == null) return;
      final itemDy = itemBox.localToGlobal(Offset.zero, ancestor: listBox).dy;
      final viewportH = _scrollController.position.viewportDimension;
      final target = (_scrollController.offset + itemDy - viewportH * 0.3).clamp(
        _scrollController.position.minScrollExtent,
        _scrollController.position.maxScrollExtent,
      );
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
    });
  }

  void _jumpTo(int segIdx, int sentIdx) {
    if (_practiceMode && _phase != _Phase.idle) _cancelPractice();
    final secs = widget.video.segments[segIdx].sentences[sentIdx].ttsStart;
    final seekTo = Duration(milliseconds: (secs * 1000).round());
    if (segIdx != _segIdx) {
      _playSegment(segIdx, seekTo: seekTo);
    } else {
      _player.seek(seekTo);
    }
    setState(() => _activeIdx = sentIdx);
    _scrollToActive(sentIdx);
  }

  void _rewind10() {
    final pos = _player.position;
    final target = pos - const Duration(seconds: 10);
    _player.seek(target < Duration.zero ? Duration.zero : target);
  }

  Future<void> _setSpeed(double speed) async {
    setState(() => _speed = speed);
    await _player.setSpeed(speed);
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ── Practice ───────────────────────────────────────────────────────────────

  void _cancelPractice() {
    _speech.cancel();
    _tts.stop();
    setState(() {
      _phase = _Phase.idle;
      _feedbackPending = false;
      _transcript = '';
      _feedback = null;
      _feedbackError = null;
      _expandedCorrections.clear();
    });
  }



  Future<void> _startRecording() async {
    if (!_speechReady) {
      setState(() {
        _phase = _Phase.done;
        _feedbackError = '裝置不支援語音辨識';
      });
      return;
    }
    setState(() {
      _transcript = '';
      _feedback = null;
      _feedbackError = null;
      _feedbackPending = false;
      _expandedCorrections.clear();
      _phase = _Phase.recording;
    });
    await _speech.listen(
      onResult: (result) {
        if (!mounted) return;
        setState(() => _transcript = result.recognizedWords);
      },
      listenFor: const Duration(seconds: 120),
      pauseFor: const Duration(seconds: 10),
      localeId: 'en-US',
      listenOptions: SpeechListenOptions(listenMode: ListenMode.dictation),
    );
  }

  void _stopRecording() {
    _speech.stop();
    setState(() => _phase = _Phase.ready);
  }

  void _doSubmitFeedback() {
    if (_feedbackPending || _phase == _Phase.evaluating || _phase == _Phase.done) return;
    _feedbackPending = true;
    setState(() => _phase = _Phase.evaluating);
    _fetchFeedback();
  }

  Future<void> _fetchFeedback() async {
    try {
      final seg = widget.video.segments[_practiceSeg];
      final res = await http.post(
        Uri.parse('$_apiBase/feedback'),
        headers: _authHeaders,
        body: jsonEncode({
          'segment_sentences': seg.sentences
              .map((s) => {'zh': s.zh, 'en': s.en})
              .toList(),
          'user_speech': _transcript,
        }),
      );
      if (!mounted) return;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      setState(() {
        _feedback = data.containsKey('error') ? null : data;
        _feedbackError = data.containsKey('error') ? data['error'] as String : null;
        _phase = _Phase.done;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _feedbackError = e.toString();
        _phase = _Phase.done;
      });
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _posSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    _scrollController.dispose();
    _speech.cancel();
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sents = widget.video.segments[_segIdx].sentences;
    final totalSegs = widget.video.segments.length;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.video.title, overflow: TextOverflow.ellipsis),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(40),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 8),
            child: Row(children: [
              SegmentedButton<_Mode>(
                style: SegmentedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 12),
                ),
                segments: const [
                  ButtonSegment(
                    value: _Mode.listen,
                    icon: Icon(Icons.hearing, size: 14),
                    label: Text('聆聽'),
                  ),
                  ButtonSegment(
                    value: _Mode.practice,
                    icon: Icon(Icons.mic, size: 14),
                    label: Text('練習'),
                  ),
                  ButtonSegment(
                    value: _Mode.summary,
                    icon: Icon(Icons.article_outlined, size: 14),
                    label: Text('摘要'),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (s) {
                  final newMode = s.first;
                  if (newMode != _Mode.practice && _phase != _Phase.idle) _cancelPractice();
                  setState(() => _mode = newMode);
                },
              ),
            ]),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.replay_10),
            tooltip: '倒退 10 秒',
            onPressed: _rewind10,
          ),
          PopupMenuButton<double>(
            initialValue: _speed,
            onSelected: _setSpeed,
            tooltip: '播放速度',
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Center(
                child: Text(
                  '${_speed == _speed.truncateToDouble() ? _speed.toInt() : _speed}x',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            itemBuilder: (_) => _speeds
                .map((s) => PopupMenuItem(
                      value: s,
                      child: Row(children: [
                        if (s == _speed)
                          const Icon(Icons.check, size: 16)
                        else
                          const SizedBox(width: 16),
                        const SizedBox(width: 8),
                        Text('${s}x'),
                      ]),
                    ))
                .toList(),
          ),
          StreamBuilder<PlayerState>(
            stream: _player.playerStateStream,
            builder: (_, snap) {
              final playing = snap.data?.playing ?? false;
              return IconButton(
                icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                onPressed: () => playing ? _player.pause() : _player.play(),
              );
            },
          ),
        ],
      ),
      // ── 進度條 ──────────────────────────────────────────────────────────────
      bottomNavigationBar: _mode == _Mode.summary ? null : StreamBuilder<Duration?>(
        stream: _player.durationStream,
        builder: (_, durSnap) => StreamBuilder<Duration>(
          stream: _player.positionStream,
          builder: (_, posSnap) {
            final dur = durSnap.data ?? Duration.zero;
            final pos = posSnap.data ?? Duration.zero;
            final progress = dur.inMilliseconds > 0
                ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
                : 0.0;
            final labelStyle = TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55),
            );
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                    ),
                    child: Slider(
                      value: progress,
                      onChanged: (v) {
                        if (dur == Duration.zero) return;
                        final ms = (v * dur.inMilliseconds).round();
                        _player.seek(Duration(milliseconds: ms));
                        // 即時更新字幕（不等 positionStream）
                        final secs = ms / 1000.0;
                        final segSents = widget.video.segments[_segIdx].sentences;
                        int active = 0;
                        for (var i = 0; i < segSents.length; i++) {
                          if (secs >= segSents[i].ttsStart) active = i;
                        }
                        if (active != _activeIdx) {
                          setState(() => _activeIdx = active);
                          _scrollToActive(active);
                        }
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 20, right: 20, bottom: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_fmt(pos), style: labelStyle),
                        Text('段落 ${_segIdx + 1} / $totalSegs', style: labelStyle),
                        Text(_fmt(dur), style: labelStyle),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
      // ── 句子列表 + 練習面板 + 摘要 ────────────────────────────────────────────
      body: _mode == _Mode.summary
          ? _buildSummaryView()
          : Column(
        children: [
          // 段落選擇列
          if (totalSegs > 1)
            SizedBox(
              height: 40,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                itemCount: totalSegs,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text('段落 ${i + 1}',
                        style: const TextStyle(fontSize: 12)),
                    selected: _segIdx == i,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) {
                      if (_phase == _Phase.recording) _speech.cancel();
                      setState(() {
                        _practiceSeg = i;
                        _phase = _Phase.idle;
                        _activeIdx = 0;
                      });
                      _playSegment(i);
                    },
                  ),
                ),
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => ListView(
                key: _listKey,
                controller: _scrollController,
                padding: EdgeInsets.only(
                  top: 8,
                  bottom: (_practiceMode && _phase != _Phase.idle)
                      ? 8
                      : constraints.maxHeight * 0.7,
                ),
                children: List.generate(sents.length, (i) {
                  final sent = sents[i];
                  final isActive = i == _activeIdx;
                  return GestureDetector(
                    key: _keys[i],
                    onTap: () => _jumpTo(_segIdx, i),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isActive
                            ? Theme.of(context).colorScheme.primaryContainer
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            sent.en,
                            style: TextStyle(
                              fontSize: isActive ? 18 : 15,
                              fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                              color: isActive
                                  ? Theme.of(context).colorScheme.onPrimaryContainer
                                  : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            sent.zh,
                            style: TextStyle(
                              fontSize: isActive ? 13 : 11,
                              color: isActive
                                  ? Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.7)
                                  : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.25),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
          if (_practiceMode) _buildPracticePanel(),
        ],
      ),

    );
  }

  // ── Practice panel ─────────────────────────────────────────────────────────

  Widget _buildPracticePanel() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(maxHeight: 320),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 36, height: 4,
                decoration: BoxDecoration(
                  color: cs.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 10),
            _buildPhaseContent(),
          ],
        ),
      ),
    );
  }

  Widget _buildPhaseContent() {
    final cs = Theme.of(context).colorScheme;
    switch (_phase) {
      case _Phase.idle:
      case _Phase.prompting:
        return FilledButton.icon(
          onPressed: _startRecording,
          icon: const Icon(Icons.mic, size: 18),
          label: const Text('開始錄音'),
        );
      case _Phase.ready:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_transcript.isNotEmpty) ...[
              _fbLabel('你說的'),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: cs.surfaceContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_transcript, style: const TextStyle(fontSize: 13)),
              ),
              const SizedBox(height: 10),
            ],
            Row(children: [
              OutlinedButton.icon(
                onPressed: _startRecording,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重新錄音'),
              ),
              const SizedBox(width: 8),
              if (_transcript.isNotEmpty)
                FilledButton.icon(
                  onPressed: _doSubmitFeedback,
                  icon: const Icon(Icons.send, size: 16),
                  label: const Text('送出批改'),
                ),
            ]),
          ],
        );
      case _Phase.recording:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 10, height: 10,
                decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('錄音中...', style: TextStyle(fontSize: 13)),
              ),
              TextButton(onPressed: _stopRecording, child: const Text('完成')),
            ]),
            if (_transcript.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: cs.surfaceContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_transcript, style: const TextStyle(fontSize: 13)),
              ),
            ],
          ],
        );
      case _Phase.evaluating:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_transcript.isNotEmpty) ...[
              _fbLabel('你說的'),
              const SizedBox(height: 4),
              Text(_transcript, style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 12),
            ],
            Row(children: [
              SizedBox(
                width: 14, height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
              ),
              const SizedBox(width: 10),
              const Text('批改中...'),
            ]),
          ],
        );
      case _Phase.done:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_transcript.isNotEmpty) ...[
              _fbLabel('你說的'),
              const SizedBox(height: 4),
              Text(_transcript, style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 12),
            ],
            if (_feedbackError != null)
              Text('批改失敗：$_feedbackError',
                  style: const TextStyle(color: Colors.red, fontSize: 12)),
            if (_feedback != null) ..._buildFeedback(_feedback!),
            const SizedBox(height: 12),
            Row(children: [
              OutlinedButton.icon(
                onPressed: () => setState(() {
                  _phase = _Phase.idle;
                  _transcript = '';
                  _feedback = null;
                  _feedbackError = null;
                  _feedbackPending = false;
                  _expandedCorrections.clear();
                }),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('再試一次'),
              ),
              const SizedBox(width: 8),
              if (_practiceSeg + 1 < widget.video.segments.length)
                FilledButton(
                  onPressed: () {
                    setState(() {
                      _practiceSeg = _practiceSeg + 1;
                      _phase = _Phase.idle;
                      _transcript = '';
                      _feedback = null;
                      _feedbackPending = false;
                      _expandedCorrections.clear();
                    });
                  },
                  child: const Text('下一段 →'),
                ),
            ]),
          ],
        );
    }
  }

  // 把修正後英文中的 [N] 換成可點擊的 chip，點擊展開/收合對應說明
  List<InlineSpan> _correctedSpans(String text, List corrections) {
    final cs = Theme.of(context).colorScheme;
    final spans = <InlineSpan>[];
    final regex = RegExp(r'\[(\d+)\]');
    int lastEnd = 0;
    for (final match in regex.allMatches(text)) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(
          text: text.substring(lastEnd, match.start),
          style: TextStyle(fontSize: 13, color: cs.onSurface),
        ));
      }
      final idx = int.parse(match.group(1)!) - 1;
      final expanded = _expandedCorrections.contains(idx);
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: GestureDetector(
          onTap: () => setState(() {
            if (expanded) {
              _expandedCorrections.remove(idx);
            } else {
              _expandedCorrections.add(idx);
            }
          }),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 2),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: expanded
                  ? cs.primary
                  : cs.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: cs.primary.withValues(alpha: 0.4)),
            ),
            child: Text(
              '[${idx + 1}]',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: expanded ? cs.onPrimary : cs.primary,
              ),
            ),
          ),
        ),
      ));
      lastEnd = match.end;
    }
    if (lastEnd < text.length) {
      spans.add(TextSpan(
        text: text.substring(lastEnd),
        style: TextStyle(fontSize: 13, color: cs.onSurface),
      ));
    }
    return spans;
  }

  List<Widget> _buildFeedback(Map<String, dynamic> fb) {
    final cs = Theme.of(context).colorScheme;
    final corrections = (fb['corrections'] as List?) ?? [];
    final corrected = fb['corrected'] as String? ?? '';
    final translationZh = fb['translation_zh'] as String? ?? '';
    final missingPoints = fb['missing_points'];
    final summary = fb['summary'] as String? ?? '';

    return [
      // 修正後英文（含可點擊的 [N] 標記）
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _fbLabel('修正後英文'),
            const SizedBox(height: 4),
            RichText(
              text: TextSpan(children: _correctedSpans(corrected, corrections)),
            ),
            // 展開的修正說明（inline，緊接在修正後英文下方）
            if (corrections.isNotEmpty) ...[
              const SizedBox(height: 6),
              ...List.generate(corrections.length, (idx) {
                if (!_expandedCorrections.contains(idx)) return const SizedBox.shrink();
                final m = corrections[idx] as Map;
                return Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainer,
                    borderRadius: BorderRadius.circular(8),
                    border: Border(left: BorderSide(color: cs.primary, width: 3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RichText(
                        text: TextSpan(
                          style: TextStyle(fontSize: 13, color: cs.onSurface),
                          children: [
                            TextSpan(
                              text: '"${m['original']}"  ',
                              style: const TextStyle(
                                color: Color(0xFFE57373),
                                decoration: TextDecoration.lineThrough,
                              ),
                            ),
                            const TextSpan(text: '→  '),
                            TextSpan(
                              text: '"${m['corrected']}"',
                              style: const TextStyle(
                                color: Color(0xFF81C784),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        m['reason'] as String? ?? '',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ],
        ),
      ),
      if (translationZh.isNotEmpty)
        _fbSection('中文翻譯', translationZh, cs.onSurface.withValues(alpha: 0.7)),
      if (missingPoints != null && missingPoints.toString() != 'null')
        _fbSection('遺漏重點', missingPoints.toString(), const Color(0xFFFFCA28)),
      if (summary.isNotEmpty)
        _fbSection('整體建議', summary, cs.onSurface.withValues(alpha: 0.75)),
    ];
  }

  Widget _fbLabel(String text) => Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.secondary,
              letterSpacing: 0.5,
            ),
      );

  Widget _fbSection(String label, String value, Color valueColor) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _fbLabel(label),
            const SizedBox(height: 3),
            Text(value, style: TextStyle(fontSize: 13, color: valueColor)),
          ],
        ),
      );

  // ── Summary view ───────────────────────────────────────────────────────────

  Widget _buildSummaryView() {
    final cs = Theme.of(context).colorScheme;
    final summary = widget.video.summary;

    if (summary == null) {
      return Center(
        child: Text('此影片無摘要',
            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.4))),
      );
    }

    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(overscroll: false),
      child: ListView(
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('影片概述',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: cs.primary,
                        letterSpacing: 0.6,
                      )),
              const SizedBox(height: 8),
              Text(summary.overview,
                  style: TextStyle(fontSize: 14, color: cs.onSurface, height: 1.7)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        ...summary.topics.map((topic) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: cs.outlineVariant),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(topic.title,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: cs.primary)),
                    const SizedBox(height: 8),
                    ...topic.points.map((p) => Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 6, right: 8),
                                child: Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    color: cs.primary.withValues(alpha: 0.7),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(p,
                                    style: TextStyle(
                                        fontSize: 13,
                                        color: cs.onSurface,
                                        height: 1.6)),
                              ),
                            ],
                          ),
                        )),
                  ],
                ),
              ),
            )),
      ],
    ));
  }
}
