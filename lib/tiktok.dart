import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'store.dart';

// TikTok has no public DM API, so we drive tiktok.com (desktop site; mobile web has no inbox).
const inboxUrl = 'https://www.tiktok.com/messages?lang=en';
const loginUrl = 'https://www.tiktok.com/login?lang=en';

final webSettings = InAppWebViewSettings(
  userAgent:
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
  preferredContentMode: UserPreferredContentMode.DESKTOP,
  useWideViewPort: true,
  loadWithOverviewMode: true,
);

Future<bool> isLoggedIn() async =>
    await CookieManager.instance()
        .getCookie(url: WebUri('https://www.tiktok.com'), name: 'sessionid') !=
    null;

Future<void> logOut() => CookieManager.instance().deleteAllCookies();

// ponytail: selectors calibrated against tiktok.com on 2026-10-18 and WILL drift.
// This block is the calibration knob: when sends start failing, fix SEL here.
const _helpers = r'''
const SEL = {
  inboxItem: '[data-e2e="dm-new-conversation-item"]',
  inboxName: '[data-e2e="dm-new-conversation-nickname"]',
  input: '[data-e2e="message-input-area"] .public-DraftEditor-content',
  send: '[data-e2e="dm-new-send-btn"]',
  msgButton: '[data-e2e="message-button"]',
  chatHandle: '[data-e2e="chat-uniqueid"]',
  chatName: '[data-e2e="dm-new-chat-nickname"]',
  chatAvatar: '[data-e2e="top-chat-avatar"]',
  chatItem: '[data-e2e="dm-new-chat-item"]',
  avatar: '[data-e2e="chat-avatar"]',
  divider: '[data-e2e="dm-new-time-separator"]',
  shareIcon: '[data-e2e="share-icon"]',
  shareGroup: '[data-e2e="share-group"]',
  shareSend: '[class*="StyledSendButton"]',
};
const $ = s => document.querySelector(s);
const $$ = s => [...document.querySelectorAll(s)];
const txt = e => ((e && e.innerText) || '').trim();
const sleep = ms => new Promise(r => setTimeout(r, ms));
const nick = e => txt(e.querySelector(SEL.inboxName) || e).split('\n')[0];
const them = () => txt($(SEL.chatHandle)).replace(/^@/, '');
const ss = {
  handle: () => them(),
  // Opens the video's Share panel; poll until true (re-clicking would toggle it shut).
  openShare() {
    if ($(SEL.shareGroup)) return true;
    const b = $(SEL.shareIcon);
    if (b) (b.closest('button') || b).click();
    return false;
  },
  // Native TikTok share: friend row is keyed "share-<handle>". Only recent chats
  // and suggestions appear there, so 'missing' means fall back to a link.
  async shareTo(h) {
    const find = () => $$('[data-e2e^="share-"]').find(e => e.getAttribute('data-e2e') === 'share-' + h);
    // The friend row fills in seconds after the panel opens and reorders while loading:
    // wait for it to hold still before clicking.
    let last = '', still = 0;
    for (let i = 0; i < 50 && still < 4; i++) {
      await sleep(500);
      const now = $$(SEL.shareGroup + ' [data-e2e^="share-"]').map(e => e.getAttribute('data-e2e')).join();
      still = now === last && find() ? still + 1 : 0;
      last = now;
    }
    const f = find();
    if (!f) return 'missing';
    f.click();
    for (let i = 0; i < 10 && !$(SEL.shareGroup + ' ' + SEL.shareSend); i++) await sleep(500);
    const b = $(SEL.shareGroup + ' ' + SEL.shareSend);
    if (!b) return 'nosend';
    b.click();
    for (let i = 0; i < 10 && $(SEL.shareGroup + ' ' + SEL.shareSend); i++) await sleep(500);
    return $(SEL.shareGroup + ' ' + SEL.shareSend) ? 'unconfirmed' : 'ok';
  },
  inbox: () => $$(SEL.inboxItem).map(e => ({name: nick(e), avatar: (e.querySelector('img') || {}).src || null})).filter(x => x.name),
  chatAvatar: () => ($(SEL.chatAvatar + ' img') || {}).src || null,
  openByName(name) {
    const e = $$(SEL.inboxItem).find(e => nick(e) === name);
    if (e) e.click();
    return !!e;
  },
  clickMessage() {
    const b = $(SEL.msgButton) || $$('button, a').find(b => txt(b) === 'Message');
    if (b) b.click();
    return !!b;
  },
  // Guard: only true once the open chat is the intended person.
  inChat(handle, name) {
    if (!$(SEL.input)) return false;
    const norm = t => (t || '').replace(/\s+/g, '');
    return handle ? them() === handle : norm(txt($(SEL.chatName))) === norm(name);
  },
  // Separators read like "October 17, 2026 22:10". A message is mine when its
  // avatar links to someone other than the chat partner.
  sentToday() {
    const isToday = t => /^today\b|^\d{1,2}:\d{2}(\s?[ap]m)?$/i.test(t) ||
      new Date(t).toDateString() === new Date().toDateString();
    const other = '/@' + them();
    let today = false;
    for (const e of $$(SEL.chatItem + ', ' + SEL.divider)) {
      if (e.matches(SEL.divider)) { today = isToday(txt(e)); continue; }
      const a = e.querySelector(SEL.avatar);
      const href = ((a && (a.closest('a') || a.querySelector('a'))) || {getAttribute: () => ''}).getAttribute('href') || '';
      if (today && href && href.split('?')[0] !== other) return true;
    }
    return false;
  },
  // execCommand('insertText') crashes TikTok's Draft.js editor; a synthetic paste doesn't.
  async send(text, dryRun) {
    const el = $(SEL.input);
    el.focus();
    const dt = new DataTransfer();
    dt.setData('text/plain', text);
    el.dispatchEvent(new ClipboardEvent('paste', {clipboardData: dt, bubbles: true, cancelable: true}));
    await sleep(1000);
    const b = $(SEL.send);
    if (!b || dryRun) return !!b;
    b.dispatchEvent(new MouseEvent('click', {bubbles: true}));
    await sleep(2500);
    return !!$(SEL.input) && txt($(SEL.input)) === '';
  },
};
''';

class _Page {
  HeadlessInAppWebView? _h;
  InAppWebViewController? _c;

  Future<void> open(String url) async {
    final ready = Completer<void>();
    _h = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(url)),
      initialSettings: webSettings,
      initialSize: const Size(1280, 900),
      onWebViewCreated: (c) => _c = c,
      onLoadStop: (_, _) => ready.isCompleted ? null : ready.complete(),
    );
    await _h!.run();
    await ready.future.timeout(const Duration(seconds: 45));
  }

  Future<void> go(String url) =>
      _c!.loadUrl(urlRequest: URLRequest(url: WebUri(url)));

  // callAsyncJavaScript never resolves if the page navigates mid-call.
  Future<dynamic> js(String expr) async => (await _c!
          .callAsyncJavaScript(functionBody: '$_helpers\nreturn await ($expr);')
          .timeout(const Duration(seconds: 15)))
      ?.value;

  /// Polls [expr] until truthy. Survives navigations mid-poll.
  Future<dynamic> until(String expr, {int secs = 30}) async {
    final end = DateTime.now().add(Duration(seconds: secs));
    while (DateTime.now().isBefore(end)) {
      try {
        final v = await js(expr);
        if (v != null && v != false) return v;
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 800));
    }
    throw TimeoutException(expr.split('(').first); // names the stuck step in the log
  }

  Future<void> close() async => _h?.dispose();
}

Future<List<Person>> fetchInbox() async {
  final p = _Page();
  try {
    await p.open(inboxUrl);
    final list = await p.until('ss.inbox().length ? ss.inbox() : null', secs: 60);
    return [for (final m in list) Person(m['name'], null, m['avatar'])];
  } finally {
    await p.close();
  }
}

/// Sends to everyone in the plan who hasn't been messaged today.
Future<void> runStreaks(Store s) async {
  final plan = planSends(s.people, s.videos, s.assigned, s.sentOn, DateTime.now());
  if (s.people.isEmpty || s.videos.isEmpty) {
    s.addLog('Skipped: add at least one person and one video.');
    return s.save();
  }
  if (plan.isEmpty) {
    s.addLog('All streaks already covered today.');
    return s.save();
  }
  if (!await isLoggedIn()) {
    s.addLog('Skipped: TikTok session expired. Log in again.');
    return s.save();
  }
  final p = _Page();
  try {
    await p.open(inboxUrl);
    for (final MapEntry(key: person, value: url) in plan.entries) {
      final who = person.handle != null ? '@${person.handle}' : person.name;
      try {
        if (person.handle != null) {
          await p.go('https://www.tiktok.com/@${person.handle}?lang=en');
          await p.until('ss.clickMessage()');
        } else {
          await p.go(inboxUrl);
          await p.until('ss.openByName(${jsonEncode(person.name)})');
        }
        await p.until('ss.inChat(${jsonEncode(person.handle)}, ${jsonEncode(person.name)})');
        await Future.delayed(const Duration(seconds: 2)); // let history render
        final pic = await p.js('ss.chatAvatar()');
        if (pic is String) s.updateAvatars([Person(person.name, person.handle, pic)]);
        if (await p.js('ss.sentToday()') == true) {
          s.sentOn[person.key] = dayKey(DateTime.now());
        s.addLog('$who: you already sent something today.');
          await s.save();
          continue;
        }
        final handle = await p.js('ss.handle()') as String;
        // Native share first; whatever it reports, their chat is the source of truth.
        var r = 'error';
        try {
          await p.go(await canonicalVideoUrl(url));
          await p.until('ss.openShare()');
          r = await p.js('ss.shareTo(${jsonEncode(handle)})') as String;
        } catch (_) {}
        await p.go('https://www.tiktok.com/@$handle?lang=en');
        await p.until('ss.clickMessage()');
        await p.until('ss.inChat(${jsonEncode(handle)}, null)');
        await Future.delayed(const Duration(seconds: 2));
        if (await p.js('ss.sentToday()') == true) {
          s.sentOn[person.key] = dayKey(DateTime.now());
          s.addLog('$who: video shared.');
        } else if (await p.js('ss.send(${jsonEncode(url)})') == true) {
          s.sentOn[person.key] = dayKey(DateTime.now());
          s.addLog('$who: sent as a link (share $r).');
        } else {
          s.addLog('$who: could not send (share $r).');
        }
      } catch (e) {
        s.addLog('$who: failed (${e is TimeoutException ? 'timed out at ${e.message}' : e.runtimeType}).');
      }
      await s.save();
    }
  } catch (e) {
    s.addLog('Could not open TikTok ($e).');
    await s.save();
  } finally {
    await p.close();
  }
}

@pragma('vm:entry-point')
Future<void> alarmCallback() async {
  // ponytail: headless WebView from the alarm isolate; if a ROM kills it,
  // move this into a foreground service.
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final s = await Store.load();
  if (!s.enabled) return;
  await schedule(s); // book tomorrow first, so a crash below can't break the chain
  await runStreaks(s);
}

Future<void> schedule(Store s) async {
  await AndroidAlarmManager.cancel(0);
  if (!s.enabled) return;
  final now = DateTime.now();
  var at = DateTime(now.year, now.month, now.day, s.hour, s.minute);
  if (!at.isAfter(now)) at = at.add(const Duration(days: 1));
  // One exact alarm per day, re-booked by alarmCallback. periodic() uses
  // setRepeating, which Android treats as inexact (observed: 18h window).
  await AndroidAlarmManager.oneShotAt(at, 0, alarmCallback,
      exact: true, wakeup: true, allowWhileIdle: true, rescheduleOnReboot: true);
}
