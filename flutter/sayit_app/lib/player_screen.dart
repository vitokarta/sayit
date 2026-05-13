import 'dart:async';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'models.dart';

const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5];

class PlayerScreen extends StatefulWidget {
  final Video video;
  const PlayerScreen({super.key, required this.video});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final _player = AudioPlayer();
  int _segIdx = 0;
  int _activeIdx = -1;
  double _speed = 1.0;
  StreamSubscription? _posSub;
  StreamSubscription? _stateSub;
  final _scrollController = ScrollController();
  final List<GlobalKey> _keys = [];
  final _listKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    for (final seg in widget.video.segments) {
      for (var _ in seg.sentences) {
        _keys.add(GlobalKey());
      }
    }
    _playSegment(0);
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
      // itemDy = item's current y position relative to ListView widget top
      final itemDy = itemBox.localToGlobal(Offset.zero, ancestor: listBox).dy;
      final viewportH = _scrollController.position.viewportDimension;
      // Scroll so item sits at 30% from top
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

  @override
  void dispose() {
    _posSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allSents = _allSentences;
    final totalSegs = widget.video.segments.length;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.video.title, overflow: TextOverflow.ellipsis),
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
                      child: Row(
                        children: [
                          if (s == _speed)
                            const Icon(Icons.check, size: 16)
                          else
                            const SizedBox(width: 16),
                          const SizedBox(width: 8),
                          Text('${s}x'),
                        ],
                      ),
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
      // ── 進度條 ──────────────────────────────────────────────
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
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.55),
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
      // ── 句子列表 ─────────────────────────────────────────────
      body: LayoutBuilder(
        builder: (context, constraints) {
          return ListView.builder(
            key: _listKey,
            controller: _scrollController,
            padding: EdgeInsets.only(top: 8, bottom: constraints.maxHeight * 0.7),
            itemCount: allSents.length,
            itemBuilder: (_, i) {
              // resolve segment + local sentence index
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
                key: _keys[i], // must use i directly — keyIdx++ breaks after scroll
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
                          fontWeight:
                              isActive ? FontWeight.bold : FontWeight.normal,
                          color: isActive
                              ? Theme.of(context).colorScheme.onPrimaryContainer
                              : Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withOpacity(0.4),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        sent.zh,
                        style: TextStyle(
                          fontSize: isActive ? 13 : 11,
                          color: isActive
                              ? Theme.of(context)
                                  .colorScheme
                                  .onPrimaryContainer
                                  .withOpacity(0.7)
                              : Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withOpacity(0.25),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
