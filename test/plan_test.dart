import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:streak_saver/store.dart';

void main() {
  test('planSends: skips sent-today, honors picks, else random library', () {
    final now = DateTime(2026, 10, 18, 20);
    const a = Person('@ana', 'ana'), b = Person('Bo'), c = Person('@cy', 'cy');
    const lib = [Video('u1', 't1'), Video('u2', 't2')];
    final plan = planSends([a, b, c], lib, {'ana': ['u2'], 'Bo': ['gone']},
        {'cy': dayKey(now)}, now, Random(1));
    expect(plan.keys, [a, b]); // cy already covered today
    expect(plan[a], 'u2'); // assigned pick
    expect(['u1', 'u2'], contains(plan[b])); // stale pick -> random
    expect(planSends([a], const [], {}, {}, now), isEmpty);
    expect(planSends([c], lib, {}, {'cy': '2026-10-17'}, now).keys, [c]); // yesterday doesn't count
  });

  test('randomSlot / nextRandomAlarm', () {
    const a = Person('@ana', 'ana'), b = Person('Bo');
    final day = DateTime(2026, 10, 19), tomorrow = DateTime(2026, 10, 20);
    for (var d = 0; d < 60; d++) { // always 9:00..23:00 on that same day
      final t = randomSlot(a, day.add(Duration(days: d)));
      expect(t.hour >= 9 && t.isBefore(DateTime(t.year, t.month, t.day, 23)), isTrue);
    }
    expect(randomSlot(a, day), randomSlot(a, day)); // stable across recomputes
    expect({for (var d = 0; d < 10; d++) randomSlot(a, day.add(Duration(days: d))).minute}.length,
        greaterThan(1)); // varies by day
    expect(randomSlot(a, day) == randomSlot(b, day), isFalse); // varies by person

    final early = DateTime(2026, 10, 19, 6); // before anyone's slot: soonest one today
    final first = [randomSlot(a, day), randomSlot(b, day)]..sort();
    expect(nextRandomAlarm([a, b], {}, early), first.first);
    // ana already sent today: her slot is skipped
    expect(nextRandomAlarm([a, b], {'ana': dayKey(day)}, early), randomSlot(b, day));
    // late in the day: tomorrow's slots
    final late = DateTime(2026, 10, 19, 23, 30);
    final next = [randomSlot(a, tomorrow), randomSlot(b, tomorrow)]..sort();
    expect(nextRandomAlarm([a, b], {}, late), next.first);
    // never sooner than 10 min out
    final justBefore = first.first.subtract(const Duration(minutes: 2));
    expect(nextRandomAlarm([a, b], {}, justBefore), justBefore.add(const Duration(minutes: 10)));
    expect(nextRandomAlarm([], {}, late), DateTime(2026, 10, 20, 9));
  });

  test('Video.stale: missing or soon-expiring thumbnail', () {
    String at(Duration d) =>
        'https://p16.tiktokcdn.com/x.image?x-expires=${DateTime.now().add(d).millisecondsSinceEpoch ~/ 1000}&x-signature=s';
    expect(const Video('u', 't').stale, isTrue);
    expect(Video('u', 't', at(const Duration(days: 2))).stale, isFalse);
    expect(Video('u', 't', at(const Duration(minutes: 10))).stale, isTrue);
    expect(const Video('u', 't', 'https://cdn/x.jpg').stale, isFalse); // unsigned: never expires
  });
}
