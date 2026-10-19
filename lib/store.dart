import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tiktok.dart' show videoInfoFromPage;

/// A TikTok person. [handle] (no @) when known, else only the inbox [name].
class Person {
  final String name;
  final String? handle;
  final String? avatar; // TikTok CDN url; signed, expires in ~a week, refreshed on use
  const Person(this.name, [this.handle, this.avatar]);
  String get key => handle ?? name;
  Map<String, dynamic> toJson() => {'name': name, 'handle': handle, 'avatar': avatar};
  factory Person.fromJson(Map m) => Person(m['name'], m['handle'], m['avatar']);
}

class Video {
  final String url;
  final String title;
  final String? thumb;
  const Video(this.url, this.title, [this.thumb]);
  Map<String, dynamic> toJson() => {'url': url, 'title': title, 'thumb': thumb};
  factory Video.fromJson(Map m) => Video(m['url'], m['title'], m['thumb']);

  /// No thumbnail yet, or its signed CDN url expires within the hour (they last ~2 days).
  bool get stale {
    final exp = int.tryParse(Uri.tryParse(thumb ?? '')?.queryParameters['x-expires'] ?? '');
    return thumb == null ||
        (exp != null && DateTime.fromMillisecondsSinceEpoch(exp * 1000)
            .isBefore(DateTime.now().add(const Duration(hours: 1))));
  }
}

final _http = HttpClient()
  ..connectionTimeout = const Duration(seconds: 6)
  ..userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

Future<Map?> _oembedOnce(String url) async {
  try {
    final res = await (await _http.getUrl(Uri.parse(
            'https://www.tiktok.com/oembed?url=${Uri.encodeComponent(url)}')))
        .close();
    final m = jsonDecode(await res.transform(utf8.decoder).join());
    return m is Map && m['thumbnail_url'] != null ? m : null; // errors come back as JSON too
  } catch (_) {
    return null;
  }
}

/// Follows a short share link (vt./vm.tiktok.com, tiktok.com/t/) to the full video url.
Future<String> _expand(String url) async {
  try {
    final res = await (await _http.getUrl(Uri.parse(url))).close();
    res.drain<void>().ignore();
    return res.redirects.isEmpty
        ? url
        : Uri.parse(url).resolveUri(res.redirects.last.location).toString();
  } catch (_) {
    return url;
  }
}

var _gate = Future<void>.value();

/// TikTok's oEmbed is slow (seen: 14s replies) and rate-limits per IP (seen: 429 on mobile
/// data for minutes at a time), so every call is queued app-wide, 3s apart.
Future<Map?> _paced(String url) {
  final r = _gate.then((_) =>
      _oembedOnce(url).timeout(const Duration(seconds: 20), onTimeout: () => null));
  _gate = r.then((_) => Future.delayed(const Duration(seconds: 3)));
  return r;
}

/// Short share links (vt./vm.tiktok.com) bounce through app-link redirects that
/// a WebView can fail on; the full @author/video/id page loads reliably.
Future<String> canonicalVideoUrl(String url) async {
  final m = await _paced(url);
  final a = m?['author_unique_id'], id = m?['embed_product_id'];
  return a != null && id != null
      ? 'https://www.tiktok.com/@$a/video/$id?lang=en'
      : await _expand(url).timeout(const Duration(seconds: 15), onTimeout: () => url);
}

String dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

/// Who gets which video right now. Skips people already sent to today;
/// assigned videos win, otherwise a random library video.
Map<Person, String> planSends(List<Person> people, List<Video> library,
    Map<String, List<String>> assigned, Map<String, String> sentOn, DateTime now,
    [Random? rng]) {
  rng ??= Random();
  final out = <Person, String>{};
  if (library.isEmpty) return out;
  for (final p in people) {
    if (sentOn[p.key] == dayKey(now)) continue;
    final pool = (assigned[p.key] ?? const <String>[])
        .where((u) => library.any((v) => v.url == u))
        .toList();
    out[p] = pool.isNotEmpty
        ? pool[rng.nextInt(pool.length)]
        : library[rng.nextInt(library.length)].url;
  }
  return out;
}

class Store extends ChangeNotifier {
  late SharedPreferences _p;
  List<Person> people = [];
  List<Video> videos = [];
  Map<String, List<String>> assigned = {};
  Map<String, String> sentOn = {};
  List<String> log = [];
  int hour = 20, minute = 0;
  bool enabled = false;

  static Future<Store> load() async {
    final s = Store().._p = await SharedPreferences.getInstance();
    await s.reload();
    return s;
  }

  /// Re-reads disk; the alarm isolate writes the same prefs.
  Future<void> reload() async {
    final s = this;
    await _p.reload();
    final j = jsonDecode(_p.getString('state') ?? '{}') as Map;
    s.people = [for (final m in j['people'] ?? []) Person.fromJson(m)];
    s.videos = [for (final m in j['videos'] ?? []) Video.fromJson(m)];
    s.assigned = {
      for (final e in (j['assigned'] as Map? ?? {}).entries)
        e.key as String: List<String>.from(e.value)
    };
    s.sentOn = Map<String, String>.from(j['sentOn'] ?? {});
    s.log = List<String>.from(j['log'] ?? []);
    s.hour = j['hour'] ?? 20;
    s.minute = j['minute'] ?? 0;
    s.enabled = j['enabled'] ?? false;
    notifyListeners();
  }

  Future<void> save() async {
    await _p.setString(
        'state',
        jsonEncode({
          'people': people,
          'videos': videos,
          'assigned': assigned,
          'sentOn': sentOn,
          'log': log,
          'hour': hour,
          'minute': minute,
          'enabled': enabled,
        }));
    notifyListeners();
  }

  void togglePerson(Person p) {
    final i = people.indexWhere((x) => x.key == p.key);
    i >= 0 ? people.removeAt(i) : people.add(p);
    save();
  }

  bool has(Person p) => people.any((x) => x.key == p.key);

  /// Refreshes stored avatars from fresh [seen] people (matched by key).
  void updateAvatars(Iterable<Person> seen) {
    for (final s in seen) {
      final i = people.indexWhere((x) => x.key == s.key);
      if (i >= 0 && s.avatar != null && people[i].avatar != s.avatar) {
        people[i] = Person(people[i].name, people[i].handle, s.avatar);
      }
    }
    save();
  }

  void addLog(String line) {
    final t = DateTime.now();
    log.insert(0,
        '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}  $line');
    if (log.length > 60) log.removeLast();
  }

  /// Shows the bare link at once, then fills in title + thumbnail.
  Future<void> addVideo(String url) async {
    url = url.trim();
    if (!url.contains('tiktok.com') || videos.any((v) => v.url == url)) return;
    videos.add(Video(url, url.replaceFirst(RegExp(r'^https?://(www\.)?'), '')));
    await save();
    await _fill(url);
  }

  Future<void>? _refreshing;

  /// Retries videos whose info never loaded and renews thumbnails before they expire.
  /// One pass at a time; launch and resume both call this.
  Future<void> refreshVideos() => _refreshing ??= () async {
        for (final v in videos.where((v) => v.stale).toList()) {
          await _fill(v.url);
        }
      }()
          .whenComplete(() => _refreshing = null);

  /// Title + thumbnail from TikTok's public oEmbed, else from the video page;
  /// keeps what's there if neither works (refreshVideos retries later).
  Future<void> _fill(String url) async {
    final m = await _paced(url) ?? await videoInfoFromPage(url);
    final i = videos.indexWhere((v) => v.url == url); // may have been removed meanwhile
    if (m == null || i < 0) return;
    final t = (m['title'] as String?)?.trim() ?? '';
    videos[i] = Video(url, t.isNotEmpty ? t : '@${m['author_unique_id']}', m['thumbnail_url']);
    await save();
  }

  void removeVideo(Video v) {
    videos.remove(v);
    for (final l in assigned.values) {
      l.remove(v.url);
    }
    save();
  }
}
