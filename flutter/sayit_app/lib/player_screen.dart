import 'dart:async';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'models.dart';

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
    final key = _keys[idx];
    final ctx = key.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(ctx,
        duration: const Duration(milliseconds: 300), alignment: 0.3);
  }

  void _jumpTo(int segIdx, int sentIdx) {
    if (segIdx != _segIdx) {
      _playSegment(segIdx);
    }
    final seg = widget.video.segments[segIdx];
    final secs = seg.sentences[sentIdx].ttsStart;
    _player.seek(Duration(milliseconds: (secs * 1000).round()));
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
      body: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(vertical: 8),
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
            onTap: () => _jumpTo(si, sj),
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
                        fontSize: 16,
                        fontWeight: isActive
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: isActive
                            ? Theme.of(context).colorScheme.onPrimaryContainer
                            : null,
                      )),
                  const SizedBox(height: 4),
                  Text(sent.zh,
                      style: TextStyle(
                        fontSize: 13,
                        color: isActive
                            ? Theme.of(context)
                                .colorScheme
                                .onPrimaryContainer
                                .withOpacity(0.7)
                            : Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withOpacity(0.5),
                      )),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
