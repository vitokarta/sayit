import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

  @override
  void initState() {
    super.initState();
    for (final seg in widget.video.segments) {
      for (var i = 0; i < seg.sentences.length; i++) {
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

  Future<void> _playSegment(int idx) async {
    if (idx >= widget.video.segments.length) return;
    setState(() => _segIdx = idx);
    final seg = widget.video.segments[idx];
    await _player.setUrl(seg.audioUrl);
    await _player.setSpeed(_speed);

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
      if (!mounted) return;
      final key = _keys[idx];
      final ctx = key.currentContext;
      if (ctx == null) return;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) return;
      final viewport = RenderAbstractViewport.of(box);
      final offset = viewport.getOffsetToReveal(box, 0.5).offset;
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        offset.clamp(0.0, _scrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
    });
  }

  void _jumpTo(int segIdx, int sentIdx, int globalIdx) {
    if (segIdx != _segIdx) {
      _playSegment(segIdx);
    }
    final seg = widget.video.segments[segIdx];
    final secs = seg.sentences[sentIdx].ttsStart;
    _player.seek(Duration(milliseconds: (secs * 1000).round()));
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
    int keyIdx = 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.video.title, overflow: TextOverflow.ellipsis),
        actions: [
          // 倒退 10s
          IconButton(
            icon: const Icon(Icons.replay_10),
            tooltip: '倒退 10 秒',
            onPressed: _rewind10,
          ),
          // 倍速選擇
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
          // 播放 / 暫停
          StreamBuilder<PlayerState>(
            stream: _player.playerStateStream,
            builder: (_, snap) {
              final playing = snap.data?.playing ?? false;
              return IconButton(
                icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                onPressed: () =>
                    playing ? _player.pause() : _player.play(),
              );
            },
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final halfH = constraints.maxHeight / 2;
          return ListView.builder(
        controller: _scrollController,
        padding: EdgeInsets.only(top: halfH, bottom: halfH),
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
          final key = _keys[keyIdx++];

          return GestureDetector(
            key: key,
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
                  Text(sent.en,
                      style: TextStyle(
                        fontSize: isActive ? 18 : 15,
                        fontWeight:
                            isActive ? FontWeight.bold : FontWeight.normal,
                        color: isActive
                            ? Theme.of(context).colorScheme.onPrimaryContainer
                            : Theme.of(context).colorScheme.onSurface.withOpacity(0.4),
                      )),
                  const SizedBox(height: 4),
                  Text(sent.zh,
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
                      )),
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
