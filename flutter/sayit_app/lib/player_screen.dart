import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'models.dart';

const _apiBase = 'https://sayit-us.onrender.com';
const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5];

enum _Phase { idle, prompting, ready, recording, evaluating, done }

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

  // ── practice ───────────────────────────────────────────────────────────────
  bool _practiceMode = false;
  final _speech = SpeechToText();
  final _tts = FlutterTts();
  bool _speechReady = false;
  _Phase _phase = _Phase.idle;
  int _practiceSeg = -1;
  String _transcript = '';
  Map<String, dynamic>? _feedback;
  String? _feedbackError;
  bool _feedbackPending = false;

  @override
  void initState() {
    super.initState();
    for (final seg in widget.video.segments) {
      for (var _ in seg.sentences) {
        _keys.add(GlobalKey());
      }
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

  List<Sentence> get _allSentences =>
      widget.video.segments.expand((s) => s.sentences).toList();

  int _globalOffset(int segIdx) {
    int offset = 0;
    for (var i = 0; i < segIdx; i++) {
      offset += widget.video.segments[i].sentences.length;
    }
    return offset;
  }

  Future<void> _playSegment(int idx, {Duration? seekTo}) async {
    if (idx >= widget.video.segments.length) return;
    setState(() => _segIdx = idx);
    final seg = widget.video.segments[idx];
    await _player.setUrl(seg.audioUrl);
    await _player.setSpeed(_speed);
    if (seekTo != null) await _player.seek(seekTo);

    _posSub?.cancel();
    _posSub = _player.positionStream.listen((pos) {
      final secs = pos.inMilliseconds / 1000.0;
      final sents = seg.sentences;
      int active = 0;
      for (var i = 0; i < sents.length; i++) {
        if (secs >= sents[i].ttsStart) active = i;
      }
      final globalActive = _globalOffset(idx) + active;
      if (globalActive != _activeIdx) {
        setState(() => _activeIdx = globalActive);
        _scrollToActive(globalActive);
      }
    });

    _stateSub?.cancel();
    _stateSub = _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        if (_practiceMode) {
          _triggerPractice(idx);
        } else {
          _playSegment(idx + 1);
        }
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

  void _jumpTo(int segIdx, int sentIdx, int globalIdx) {
    if (_practiceMode && _phase != _Phase.idle) _cancelPractice();
    final secs = widget.video.segments[segIdx].sentences[sentIdx].ttsStart;
    final seekTo = Duration(milliseconds: (secs * 1000).round());
    if (segIdx != _segIdx) {
      _playSegment(segIdx, seekTo: seekTo);
    } else {
      _player.seek(seekTo);
    }
    setState(() => _activeIdx = globalIdx);
    _scrollToActive(globalIdx);
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
    });
  }

  void _triggerPractice(int segIdx) {
    setState(() {
      _practiceSeg = segIdx;
      _phase = _Phase.prompting;
      _transcript = '';
      _feedback = null;
      _feedbackError = null;
      _feedbackPending = false;
    });
    _tts.speak('Now try to describe what you heard.');
  }

  Future<void> _startRecording() async {
    if (!_speechReady) {
      setState(() {
        _phase = _Phase.done;
        _feedbackError = '裝置不支援語音辨識';
      });
      return;
    }
    setState(() => _phase = _Phase.recording);
    await _speech.listen(
      onResult: (result) {
        if (!mounted) return;
        setState(() => _transcript = result.recognizedWords);
      },
      listenFor: const Duration(seconds: 120),
      localeId: 'en-US',
    );
  }

  void _stopRecording() {
    _speech.stop();
    if (_transcript.isNotEmpty) {
      _doSubmitFeedback();
    } else {
      setState(() => _phase = _Phase.ready);
    }
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
        headers: {'Content-Type': 'application/json'},
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
    final allSents = _allSentences;
    final totalSegs = widget.video.segments.length;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.video.title, overflow: TextOverflow.ellipsis),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(40),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 8),
            child: Row(children: [
              SegmentedButton<bool>(
                style: SegmentedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 12),
                ),
                segments: const [
                  ButtonSegment(
                    value: false,
                    icon: Icon(Icons.hearing, size: 14),
                    label: Text('聆聽'),
                  ),
                  ButtonSegment(
                    value: true,
                    icon: Icon(Icons.mic, size: 14),
                    label: Text('練習'),
                  ),
                ],
                selected: {_practiceMode},
                onSelectionChanged: (s) {
                  final newMode = s.first;
                  if (!newMode && _phase != _Phase.idle) _cancelPractice();
                  setState(() => _practiceMode = newMode);
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
      bottomNavigationBar: StreamBuilder<Duration?>(
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
                        _player.seek(Duration(
                            milliseconds: (v * dur.inMilliseconds).round()));
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
      // ── 句子列表 + 練習面板 ────────────────────────────────────────────────
      body: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => ListView.builder(
                key: _listKey,
                controller: _scrollController,
                padding: EdgeInsets.only(
                  top: 8,
                  bottom: (_practiceMode && _phase != _Phase.idle)
                      ? 8
                      : constraints.maxHeight * 0.7,
                ),
                itemCount: allSents.length,
                itemBuilder: (_, i) {
                  int si = 0, sj = 0, count = 0;
                  for (var s = 0; s < widget.video.segments.length; s++) {
                    final len = widget.video.segments[s].sentences.length;
                    if (count + len > i) {
                      si = s;
                      sj = i - count;
                      break;
                    }
                    count += len;
                  }
                  final sent = allSents[i];
                  final isActive = i == _activeIdx;

                  return GestureDetector(
                    key: _keys[i],
                    onTap: () => _jumpTo(si, sj, i),
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
                },
              ),
            ),
          ),
          if (_practiceMode && _phase != _Phase.idle) _buildPracticePanel(),
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
            Text(
              '段落 ${_practiceSeg + 1} 練習',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cs.primary),
            ),
            const SizedBox(height: 12),
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
        return const SizedBox.shrink();
      case _Phase.prompting:
        return Row(children: [
          SizedBox(
            width: 14, height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: cs.secondary),
          ),
          const SizedBox(width: 10),
          const Text('提示播放中...'),
        ]);
      case _Phase.ready:
        return FilledButton.icon(
          onPressed: _startRecording,
          icon: const Icon(Icons.mic, size: 18),
          label: const Text('開始錄音'),
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
            SizedBox(
              width: double.infinity,
              child: _practiceSeg + 1 < widget.video.segments.length
                  ? FilledButton(
                      onPressed: () {
                        setState(() => _phase = _Phase.idle);
                        _playSegment(_practiceSeg + 1);
                      },
                      child: const Text('下一段 →'),
                    )
                  : OutlinedButton(
                      onPressed: () => setState(() => _phase = _Phase.idle),
                      child: const Text('完成'),
                    ),
            ),
          ],
        );
    }
  }

  List<Widget> _buildFeedback(Map<String, dynamic> fb) {
    final cs = Theme.of(context).colorScheme;
    final corrections = (fb['corrections'] as List?) ?? [];
    final corrected = fb['corrected'] as String? ?? '';
    final translationZh = fb['translation_zh'] as String? ?? '';
    final missingPoints = fb['missing_points'];
    final summary = fb['summary'] as String? ?? '';

    return [
      _fbSection('修正後英文', corrected, cs.onSurface),
      if (translationZh.isNotEmpty)
        _fbSection('中文翻譯', translationZh, cs.onSurface.withValues(alpha: 0.7)),
      if (missingPoints != null && missingPoints.toString() != 'null')
        _fbSection('遺漏重點', missingPoints.toString(), const Color(0xFFE0C060)),
      if (corrections.isNotEmpty) ...[
        const SizedBox(height: 4),
        _fbLabel('修正說明'),
        const SizedBox(height: 6),
        ...corrections.map((c) {
          final m = c as Map;
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Container(
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
                          text: '[${m['id']}] ',
                          style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold),
                        ),
                        TextSpan(
                          text: '"${m['original']}"  ',
                          style: const TextStyle(
                            color: Colors.redAccent,
                            decoration: TextDecoration.lineThrough,
                          ),
                        ),
                        const TextSpan(text: '→  '),
                        TextSpan(
                          text: '"${m['corrected']}"',
                          style: const TextStyle(
                            color: Colors.lightGreenAccent,
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
            ),
          );
        }),
      ],
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
}
