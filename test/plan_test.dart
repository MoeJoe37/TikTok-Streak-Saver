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

  test('Video.stale: missing or soon-expiring thumbnail', () {
    String at(Duration d) =>
        'https://p16.tiktokcdn.com/x.image?x-expires=${DateTime.now().add(d).millisecondsSinceEpoch ~/ 1000}&x-signature=s';
    expect(const Video('u', 't').stale, isTrue);
    expect(Video('u', 't', at(const Duration(days: 2))).stale, isFalse);
    expect(Video('u', 't', at(const Duration(minutes: 10))).stale, isTrue);
    expect(const Video('u', 't', 'https://cdn/x.jpg').stale, isFalse); // unsigned: never expires
  });
}
