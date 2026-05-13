import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';
import 'player_screen.dart';

const _apiBase = 'https://sayit-x056.onrender.com';
const _historyKey = 'history';
const _maxHistory = 3;

void main() {
  runApp(const SayItApp());
}

class SayItApp extends StatelessWidget {
  const SayItApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SayIt',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _urlController = TextEditingController();
  bool _loading = false;
  String? _error;
  List<Map<String, String>> _history = [];

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_historyKey);
    if (raw != null) {
      setState(() {
        _history = (jsonDecode(raw) as List)
            .map((e) => Map<String, String>.from(e as Map))
            .toList();
      });
    }
  }

  Future<void> _saveToHistory(String id, String title) async {
    final prefs = await SharedPreferences.getInstance();
    _history.removeWhere((e) => e['id'] == id);
    _history.insert(0, {'id': id, 'title': title});
    if (_history.length > _maxHistory) _history = _history.sublist(0, _maxHistory);
    await prefs.setString(_historyKey, jsonEncode(_history));
    setState(() {});
  }

  Future<void> _process() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    setState(() { _loading = true; _error = null; });

    try {
      final res = await http.post(
        Uri.parse('$_apiBase/process'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'url': url}),
      );
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final videoId = body['video_id'] as String;
      await _openVideo(videoId);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _openVideo(String videoId) async {
    setState(() { _loading = true; _error = null; });
    try {
      final res = await http.get(Uri.parse('$_apiBase/video/$videoId'));
      if (res.statusCode != 200) throw Exception('找不到影片');
      final video = Video.fromJson(
          jsonDecode(res.body) as Map<String, dynamic>);
      await _saveToHistory(video.id, video.title);
      if (!mounted) return;
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => PlayerScreen(video: video)));
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SayIt')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          // 歷史紀錄
          if (_history.isNotEmpty) ...[
            Text('最近播放',
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(color: Theme.of(context).colorScheme.primary)),
            const SizedBox(height: 8),
            ..._history.map((item) => Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: const Icon(Icons.history),
                    title: Text(item['title'] ?? '',
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _loading ? null : () => _openVideo(item['id']!),
                  ),
                )),
            const SizedBox(height: 20),
          ],

          // URL 輸入
          TextField(
            controller: _urlController,
            decoration: const InputDecoration(
              labelText: 'YouTube URL',
              border: OutlineInputBorder(),
              hintText: 'https://www.youtube.com/watch?v=...',
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _loading ? null : _process,
              child: _loading
                  ? const SizedBox(
                      height: 20, width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('開始處理'),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.red)),
          ],
        ],
      ),
    );
  }
}
