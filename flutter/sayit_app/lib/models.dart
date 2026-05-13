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

class SummaryTopic {
  final String title;
  final List<String> points;

  SummaryTopic({required this.title, required this.points});

  factory SummaryTopic.fromJson(Map<String, dynamic> j) => SummaryTopic(
        title: j['title'] as String,
        points: (j['points'] as List).map((p) => p as String).toList(),
      );
}

class Summary {
  final String overview;
  final List<SummaryTopic> topics;

  Summary({required this.overview, required this.topics});

  factory Summary.fromJson(Map<String, dynamic> j) => Summary(
        overview: j['overview'] as String,
        topics: (j['topics'] as List)
            .map((t) => SummaryTopic.fromJson(t as Map<String, dynamic>))
            .toList(),
      );
}

class Video {
  final String id;
  final String title;
  final List<Segment> segments;
  final Summary? summary;

  Video({required this.id, required this.title, required this.segments, this.summary});

  factory Video.fromJson(Map<String, dynamic> j) {
    final data = j['data'] as Map<String, dynamic>;
    return Video(
      id: j['id'] as String,
      title: j['title'] as String,
      segments: (data['segments'] as List)
          .map((s) => Segment.fromJson(s as Map<String, dynamic>))
          .toList(),
      summary: data['summary'] != null
          ? Summary.fromJson(data['summary'] as Map<String, dynamic>)
          : null,
    );
  }
}
