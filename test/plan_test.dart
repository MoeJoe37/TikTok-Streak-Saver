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
}
