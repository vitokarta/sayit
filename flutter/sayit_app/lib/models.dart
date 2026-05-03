class Sentence {
  final String zh;
  final String en;
  final double ttsStart;

  Sentence({required this.zh, required this.en, required this.ttsStart});

  factory Sentence.fromJson(Map<String, dynamic> j) => Sentence(
        zh: j['zh'] as String,
        en: j['en'] as String,
        ttsStart: (j['tts_start'] as num).toDouble(),
      );
}

class Segment {
  final String audioUrl;
  final List<Sentence> sentences;

  Segment({required this.audioUrl, required this.sentences});

  factory Segment.fromJson(Map<String, dynamic> j) => Segment(
        audioUrl: j['audio_url'] as String,
        sentences: (j['sentences'] as List)
            .map((s) => Sentence.fromJson(s as Map<String, dynamic>))
            .toList(),
      );
}

class Video {
  final String id;
  final String title;
  final List<Segment> segments;

  Video({required this.id, required this.title, required this.segments});

  factory Video.fromJson(Map<String, dynamic> j) {
    final data = j['data'] as Map<String, dynamic>;
    return Video(
      id: j['id'] as String,
      title: j['title'] as String,
      segments: (data['segments'] as List)
          .map((s) => Segment.fromJson(s as Map<String, dynamic>))
          .toList(),
    );
  }
}
