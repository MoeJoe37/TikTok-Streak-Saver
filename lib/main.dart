import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'store.dart';
import 'tiktok.dart';

late final Store store;
final running = ValueNotifier(false);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AndroidAlarmManager.initialize();
  store = await Store.load();
  await schedule(store); // app updates wipe alarms; re-book on every launch
  store.refreshVideos(); // background; tiles update as info arrives
  runApp(App(loggedIn: await isLoggedIn()));
}

// One accent (ember), one radius scale: 16 for surfaces, pill for buttons/search.
const ember = Color(0xFFE4572E);

ThemeData _theme(Brightness b) {
  final cs = ColorScheme.fromSeed(
      seedColor: ember, brightness: b, dynamicSchemeVariant: DynamicSchemeVariant.fidelity);
  return ThemeData(
    colorScheme: cs,
    scaffoldBackgroundColor: cs.surface,
    appBarTheme: AppBarTheme(backgroundColor: cs.surface, scrolledUnderElevation: 0),
    chipTheme: const ChipThemeData(shape: StadiumBorder()),
    bottomSheetTheme: const BottomSheetThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16)))),
    filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54))),
  );
}

class App extends StatefulWidget {
  const App({super.key, required this.loggedIn});
  final bool loggedIn;
  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  late bool loggedIn = widget.loggedIn;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Streak Saver',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        home: loggedIn
            ? Home(onLogout: () async {
                await logOut();
                setState(() => loggedIn = false);
              })
            : Welcome(onLogin: () => setState(() => loggedIn = true)),
      );
}

class Welcome extends StatelessWidget {
  const Welcome({super.key, required this.onLogin});
  final VoidCallback onLogin;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme, cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Spacer(flex: 3),
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(16)),
              child: Icon(Icons.local_fire_department_rounded, size: 36, color: cs.onPrimaryContainer),
            ),
            const SizedBox(height: 28),
            Text('Keep every\nstreak alive.',
                style: t.displaySmall?.copyWith(fontWeight: FontWeight.w700, height: 1.08, letterSpacing: -1)),
            const SizedBox(height: 16),
            Text('Pick your people, pick the videos, pick a time. Streak Saver only sends when you forgot.',
                style: t.bodyLarge?.copyWith(color: cs.onSurfaceVariant, height: 1.45)),
            const Spacer(flex: 4),
            FilledButton.icon(
              icon: const Icon(Icons.login_rounded),
              label: const Text('Log in with TikTok'),
              onPressed: () async {
                final ok = await Navigator.push<bool>(
                    context, MaterialPageRoute(builder: (_) => const LoginPage()));
                if (ok == true) onLogin();
              },
            ),
            const SizedBox(height: 12),
            Text('Google and Apple sign-in are blocked inside apps. Use phone, email or username.',
                style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ]),
        ),
      ),
    );
  }
}

class LoginPage extends StatelessWidget {
  const LoginPage({super.key});

  @override
  Widget build(BuildContext context) {
    var done = false;
    Future<void> check() async {
      if (!done && await isLoggedIn() && context.mounted) {
        done = true;
        Navigator.pop(context, true);
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Log in to TikTok')),
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(loginUrl)),
        initialSettings: webSettings,
        onLoadStop: (_, _) => check(),
        onUpdateVisitedHistory: (_, _, _) => check(),
      ),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key, required this.onLogout});
  final VoidCallback onLogout;
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;
  late final _life = AppLifecycleListener(onResume: () {
    store.reload().then((_) => store.refreshVideos());
    checkBlockers(); // user may be back from a settings page
  });

  @override
  void initState() {
    super.initState();
    // Ask once per launch, only when a schedule is actually relying on it.
    checkBlockers().then((_) {
      if (mounted && store.enabled && blockers.value.isNotEmpty) showBlockers(context);
    });
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    final url = RegExp(r'https?://\S*tiktok\.com\S*').firstMatch(text)?.group(0);
    if (!mounted) return;
    if (url == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Copy a TikTok video link first.')));
      return;
    }
    await store.addVideo(url);
  }

  @override
  Widget build(BuildContext context) {
    _life; // start listening
    return Scaffold(
      appBar: AppBar(
        title: Text(['People', 'Videos', 'Schedule'][tab],
            style: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.5)),
        actions: [
          PopupMenuButton(
            itemBuilder: (_) => [PopupMenuItem(onTap: widget.onLogout, child: const Text('Log out'))],
          ),
        ],
      ),
      body: IndexedStack(index: tab, children: const [PeopleTab(), VideosTab(), ScheduleTab()]),
      floatingActionButton: tab == 1
          ? FloatingActionButton.extended(
              onPressed: _paste,
              icon: const Icon(Icons.content_paste_rounded),
              label: const Text('Paste link'))
          : null,
      bottomNavigationBar: ListenableBuilder(
        listenable: store,
        builder: (_, _) => NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) => setState(() => tab = i),
          destinations: [
            NavigationDestination(
                icon: Badge(
                    isLabelVisible: store.people.isNotEmpty,
                    label: Text('${store.people.length}'),
                    child: const Icon(Icons.people_alt_outlined)),
                selectedIcon: const Icon(Icons.people_alt_rounded),
                label: 'People'),
            const NavigationDestination(
                icon: Icon(Icons.video_library_outlined),
                selectedIcon: Icon(Icons.video_library_rounded),
                label: 'Videos'),
            const NavigationDestination(
                icon: Icon(Icons.schedule_outlined),
                selectedIcon: Icon(Icons.schedule_rounded),
                label: 'Schedule'),
          ],
        ),
      ),
    );
  }
}

// ---------- People ----------

class PeopleTab extends StatefulWidget {
  const PeopleTab({super.key});
  @override
  State<PeopleTab> createState() => _PeopleTabState();
}

class _PeopleTabState extends State<PeopleTab> {
  final ctrl = TextEditingController();
  List<Person> inbox = [];
  bool loading = false, failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      failed = false;
    });
    try {
      inbox = await fetchInbox();
      store.updateAvatars(inbox);
    } catch (_) {
      failed = true;
    }
    if (mounted) setState(() => loading = false);
  }

  void _add(String raw) {
    final h = raw.trim().replaceFirst('@', '').toLowerCase();
    if (!RegExp(r'^[a-z0-9._]{2,24}$').hasMatch(h)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('That is not a valid TikTok username.')));
      return;
    }
    final p = Person('@$h', h);
    if (!store.has(p)) store.togglePerson(p);
    ctrl.clear();
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
          SearchBar(
            controller: ctrl,
            hintText: 'Add by @username',
            elevation: const WidgetStatePropertyAll(0),
            backgroundColor: WidgetStatePropertyAll(cs.surfaceContainerHigh),
            leading: const Padding(padding: EdgeInsets.only(left: 8), child: Icon(Icons.search_rounded)),
            trailing: [IconButton(icon: const Icon(Icons.add_rounded), tooltip: 'Add', onPressed: () => _add(ctrl.text))],
            onSubmitted: _add,
          ),
          const SizedBox(height: 24),
          if (store.people.isNotEmpty) ...[
            _Label('Sending to ${store.people.length}'),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final p in store.people)
                InputChip(
                  avatar: _Avatar(p),
                  label: Text(p.name),
                  onDeleted: () => store.togglePerson(p),
                ),
            ]),
            const SizedBox(height: 28),
          ],
          Row(children: [
            const _Label('Your inbox'),
            const Spacer(),
            IconButton(
                icon: const Icon(Icons.refresh_rounded), tooltip: 'Reload', onPressed: loading ? null : _load),
          ]),
          if (loading)
            for (var i = 0; i < 6; i++) const _SkeletonRow()
          else if (failed)
            _Empty(
              icon: Icons.cloud_off_rounded,
              title: 'Could not read your inbox',
              body: 'You may be offline, or TikTok changed its page. You can still add people by username.',
              action: TextButton(onPressed: _load, child: const Text('Try again')),
            )
          else if (inbox.isEmpty)
            const _Empty(
              icon: Icons.forum_outlined,
              title: 'No conversations yet',
              body: 'Search by username above to add someone.',
            )
          else
            for (final p in inbox)
              Builder(builder: (_) {
                final on = store.has(p);
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: _Avatar(p, radius: 20),
                  title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                    child: Icon(on ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                        key: ValueKey(on), color: on ? cs.primary : cs.outline),
                  ),
                  onTap: () => store.togglePerson(p),
                );
              }),
        ]),
      ),
    );
  }
}

// ---------- Videos ----------

class VideosTab extends StatelessWidget {
  const VideosTab({super.key});

  Future<void> _remove(BuildContext context, Video v) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Remove this video?'),
        content: Text(v.title, maxLines: 3, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true) store.removeVideo(v);
  }

  void _pick(BuildContext context, Person p) => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (c) => SizedBox(
          height: MediaQuery.sizeOf(c).height * 0.75,
          child: ListenableBuilder(
            listenable: store,
            builder: (c, _) {
              final picked = store.assigned[p.key] ?? [];
              final t = Theme.of(c).textTheme;
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Videos for ${p.name}', style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(picked.isEmpty ? 'None picked, so a random library video is sent.' : 'One of these ${picked.length} is sent each day.',
                        style: t.bodyMedium?.copyWith(color: Theme.of(c).colorScheme.onSurfaceVariant)),
                  ]),
                ),
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    gridDelegate: _grid,
                    itemCount: store.videos.length,
                    itemBuilder: (_, i) {
                      final v = store.videos[i];
                      return _VideoTile(v, selected: picked.contains(v.url), onTap: () {
                        final l = store.assigned.putIfAbsent(p.key, () => []);
                        l.contains(v.url) ? l.remove(v.url) : l.add(v.url);
                        store.save();
                      });
                    },
                  ),
                ),
              ]);
            },
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          if (store.videos.isEmpty) {
            return const _Empty(
              icon: Icons.video_library_outlined,
              title: 'No videos yet',
              body: 'In TikTok, tap Share on a video, then Copy link. Come back here and tap Paste link.',
            );
          }
          final cs = Theme.of(context).colorScheme;
          return CustomScrollView(slivers: [
            const SliverPadding(padding: EdgeInsets.fromLTRB(16, 4, 16, 0), sliver: SliverToBoxAdapter(child: _Label('Library'))),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverGrid.builder(
                gridDelegate: _grid,
                itemCount: store.videos.length,
                itemBuilder: (_, i) => _VideoTile(store.videos[i],
                    onLongPress: () => _remove(context, store.videos[i])),
              ),
            ),
            const SliverPadding(padding: EdgeInsets.fromLTRB(16, 28, 16, 0), sliver: SliverToBoxAdapter(child: _Label('Who gets what'))),
            if (store.people.isEmpty)
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverToBoxAdapter(
                    child: Text('Add people in the People tab first.', style: TextStyle(color: cs.onSurfaceVariant))),
              ),
            SliverList.builder(
              itemCount: store.people.length,
              itemBuilder: (_, i) {
                final p = store.people[i], n = store.assigned[p.key]?.length ?? 0;
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  leading: _Avatar(p, radius: 20),
                  title: Text(p.name),
                  subtitle: Text(n == 0 ? 'Random from library' : '$n picked, one per day'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _pick(context, p),
                );
              },
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 104)), // clear the FAB
          ]);
        },
      );
}

const _grid = SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: 3, childAspectRatio: 9 / 16, mainAxisSpacing: 8, crossAxisSpacing: 8);

class _VideoTile extends StatelessWidget {
  const _VideoTile(this.v, {this.selected = false, this.onTap, this.onLongPress});
  final Video v;
  final bool selected;
  final VoidCallback? onTap, onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fallback = ColoredBox(
        color: cs.surfaceContainerHighest,
        child: Center(child: Icon(Icons.play_arrow_rounded, size: 32, color: cs.onSurfaceVariant)));
    return Semantics(
      button: true,
      selected: selected,
      label: v.title,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: AnimatedScale(
          scale: selected ? 0.94 : 1,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(fit: StackFit.expand, children: [
              v.thumb == null
                  ? fallback
                  : Image.network(v.thumb!, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback),
              const DecoratedBox(
                decoration: BoxDecoration(
                    gradient: LinearGradient(
                        begin: Alignment.center,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Color(0xCC111111)])),
              ),
              Positioned(
                left: 8,
                right: 8,
                bottom: 8,
                child: Text(v.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Color(0xFFF5F5F5), fontSize: 11, height: 1.25)),
              ),
              if (selected) ...[
                DecoratedBox(
                    decoration: BoxDecoration(
                        border: Border.all(color: cs.primary, width: 3),
                        borderRadius: BorderRadius.circular(16))),
                Positioned(
                  top: 6,
                  right: 6,
                  child: CircleAvatar(
                      radius: 12,
                      backgroundColor: cs.primary,
                      child: Icon(Icons.check_rounded, size: 16, color: cs.onPrimary)),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

// ---------- Schedule ----------

class ScheduleTab extends StatelessWidget {
  const ScheduleTab({super.key});

  Future<void> _pickTime(BuildContext context) async {
    final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: store.hour, minute: store.minute));
    if (t == null) return;
    store
      ..hour = t.hour
      ..minute = t.minute;
    await store.save();
    await schedule(store);
  }

  Future<void> _runNow() async {
    running.value = true;
    try {
      await runStreaks(store);
    } finally {
      running.value = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme, cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([store, running, blockers]),
      builder: (context, _) {
        final time = TimeOfDay(hour: store.hour, minute: store.minute).format(context);
        final issues = [
          if (store.people.isEmpty) 'Add at least one person.',
          if (store.videos.isEmpty) 'Add at least one video.',
        ];
        return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => _pickTime(context),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(time,
                    style: t.displayLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        letterSpacing: -2,
                        color: store.enabled ? cs.onSurface : cs.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()])),
                Text('Tap to change the daily check time', style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ]),
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Daily check'),
            subtitle: Text('At $time, send a video to anyone you have not messaged today.'),
            value: store.enabled,
            onChanged: (v) async {
              store.enabled = v;
              await store.save();
              await schedule(store);
              await checkBlockers();
              if (v && blockers.value.isNotEmpty && context.mounted) showBlockers(context);
            },
          ),
          if (store.enabled && blockers.value.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Material(
                color: cs.errorContainer,
                borderRadius: BorderRadius.circular(16),
                child: ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  leading: Icon(Icons.battery_alert_rounded, color: cs.onErrorContainer),
                  title: Text(
                      blockers.value.length == 1
                          ? '1 phone setting may stop scheduled sends'
                          : '${blockers.value.length} phone settings may stop scheduled sends',
                      style: TextStyle(color: cs.onErrorContainer)),
                  trailing: Text('Fix', style: TextStyle(color: cs.onErrorContainer, fontWeight: FontWeight.w700)),
                  onTap: () => showBlockers(context),
                ),
              ),
            ),
          for (final i in issues)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(children: [
                Icon(Icons.error_outline_rounded, size: 18, color: cs.error),
                const SizedBox(width: 8),
                Text(i, style: TextStyle(color: cs.error)),
              ]),
            ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: running.value || issues.isNotEmpty ? null : _runNow,
            icon: running.value
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send_rounded),
            label: Text(running.value ? 'Checking' : 'Check now'),
          ),
          const SizedBox(height: 32),
          const _Label('Activity'),
          if (store.log.isEmpty)
            Text('Nothing yet. Each run shows up here.', style: TextStyle(color: cs.onSurfaceVariant))
          else
            for (final l in store.log)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(l,
                    style: t.bodyMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
              ),
        ]);
      },
    );
  }
}

// ---------- Background blockers ----------

const _blockerChannel = MethodChannel('streak_saver/blockers');

/// Phone settings currently able to stop the alarm run (see MainActivity.kt).
final blockers = ValueNotifier<List<String>>([]);

Future<void> checkBlockers() async {
  try {
    blockers.value = List<String>.from(await _blockerChannel.invokeMethod('check'));
  } on PlatformException catch (_) {}
}

const _blockerText = {
  'battery': ('Battery saver is limiting the app', 'Your phone may close Streak Saver before it sends. Choose No restrictions or Allow.'),
  'autostart': ('Autostart is off', 'Your phone blocks Streak Saver from waking up at the set time. Turn it on.'),
  'background': ('Background use is restricted', 'Streak Saver cannot run while closed. Remove the restriction.'),
  'alarm': ('Exact alarms are off', 'The daily check could run hours late. Allow alarms and reminders.'),
};

void showBlockers(BuildContext context) => showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => ValueListenableBuilder(
        valueListenable: blockers,
        builder: (c, list, _) {
          final t = Theme.of(c).textTheme, cs = Theme.of(c).colorScheme;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(list.isEmpty ? 'All set' : 'Keep sends working',
                    style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text(
                    list.isEmpty
                        ? 'Nothing on this phone is blocking scheduled sends.'
                        : 'These settings can stop Streak Saver from sending while it is closed.',
                    style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                const SizedBox(height: 12),
                for (final b in list)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.error_outline_rounded, color: cs.error),
                    title: Text(_blockerText[b]?.$1 ?? b),
                    subtitle: Text(_blockerText[b]?.$2 ?? ''),
                    trailing: FilledButton.tonal(
                      style: FilledButton.styleFrom(minimumSize: const Size(64, 40)),
                      onPressed: () => _blockerChannel.invokeMethod('fix', b),
                      child: const Text('Fix'),
                    ),
                  ),
                if (list.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Done')),
                  ),
              ]),
            ),
          );
        },
      ),
    );

// ---------- Shared bits ----------

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}

class _Avatar extends StatelessWidget {
  const _Avatar(this.p, {this.radius = 12});
  final Person p;
  final double radius;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final letter = p.name.replaceFirst('@', '').characters.firstOrNull?.toUpperCase() ?? '?';
    return CircleAvatar(
      radius: radius,
      backgroundColor: cs.primaryContainer,
      // Letter stays underneath; an expired or failed picture just shows it.
      foregroundImage: p.avatar == null ? null : NetworkImage(p.avatar!),
      onForegroundImageError: p.avatar == null ? null : (_, _) {},
      child: Text(letter,
          style: TextStyle(color: cs.onPrimaryContainer, fontSize: radius * 0.9, fontWeight: FontWeight.w600)),
    );
  }
}

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow();
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme.surfaceContainerHighest;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(children: [
        CircleAvatar(radius: 20, backgroundColor: c),
        const SizedBox(width: 16),
        Container(width: 140, height: 14, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(16))),
      ]),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.body, this.action});
  final IconData icon;
  final String title, body;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme, cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 40, color: cs.primary),
        const SizedBox(height: 16),
        Text(title, style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(body, style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant, height: 1.4)),
        if (action != null) Padding(padding: const EdgeInsets.only(top: 8), child: action),
      ]),
    );
  }
}
