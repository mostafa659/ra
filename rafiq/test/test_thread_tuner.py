import json
import os
import random
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools", "frame_engine"))

import gen_report_fixtures as gen  # noqa: E402
import report_ref as rr  # noqa: E402
import thread_tuner_ref as tt  # noqa: E402

LONG = {"steps": 40, "audio_seconds": 20.0}


def run(state, cores, threads, rtf, **kw):
    args = dict(LONG)
    args.update(kw)
    return tt.observe(state, cores, threads, rtf, args["steps"], args["audio_seconds"])


class CandidateTests(unittest.TestCase):
    def test_candidates_and_the_shipped_guess(self):
        self.assertEqual(tt.candidates(1), [1])
        self.assertEqual(tt.candidates(2), [1, 2])
        self.assertEqual(tt.candidates(8), [1, 2, 3, 4])
        self.assertEqual(tt.candidates(64), [1, 2, 3, 4])
        self.assertEqual([tt.default_threads(c) for c in (1, 2, 4, 5, 6, 8)], [1, 2, 2, 2, 3, 3])

    def test_the_speed_limit_is_the_one_the_report_uses(self):
        self.assertEqual(tt.OK_RTF, rr.RTF_TIGHT)

    def test_a_stored_count_is_clamped_to_this_phone(self):
        self.assertEqual(tt.threads_for({"threads": 4}, 2), 2)
        self.assertEqual(tt.threads_for({"threads": 0}, 8), 3)
        self.assertEqual(tt.threads_for({}, 8), 3)
        self.assertEqual(tt.threads_for({"threads": 4}, 8), 4)


class PolicyTests(unittest.TestCase):
    def test_a_fast_phone_is_never_touched(self):
        state = tt.initial_state(8)
        for rtf in (0.3, 0.79, 0.5, 0.7, 0.2) * 5:
            state = run(state, 8, 3, rtf)
            self.assertEqual(state["threads"], 3)
        self.assertTrue(state["settled"])

    def test_a_tight_phone_tries_the_nearest_untried_count_fewer_first(self):
        state = run(tt.initial_state(8), 8, 3, 0.95)
        self.assertEqual(state["threads"], 2)         # 2 and 4 are equally near: fewer first
        self.assertFalse(state["settled"])
        state = run(state, 8, 2, 0.9)
        self.assertEqual(state["threads"], 1)
        state = run(state, 8, 1, 1.4)
        self.assertEqual(state["threads"], 4)

    def test_it_settles_on_the_first_count_that_is_comfortably_fast(self):
        state = tt.initial_state(8)
        state = run(state, 8, 3, 1.2)
        state = run(state, 8, 2, 0.55)
        self.assertEqual((state["threads"], state["settled"]), (2, True))
        self.assertAlmostEqual(state["baseline"], 0.55)

    def test_clearing_the_limit_by_a_hair_keeps_looking_for_more_margin(self):
        state = run(tt.initial_state(8), 8, 3, 1.0)
        state = run(state, 8, 2, 0.75)               # under 0.8 but not under 0.6: try the next count too
        self.assertFalse(state["settled"])
        self.assertEqual(state["threads"], 1)
        state = run(state, 8, 1, 0.5)
        self.assertEqual((state["threads"], state["settled"]), (1, True))

    def test_the_first_measurement_under_the_limit_settles_at_once(self):
        state = run(tt.initial_state(8), 8, 3, 0.75)
        self.assertEqual((state["threads"], state["settled"]), (3, True))

    def test_when_nothing_is_fast_enough_the_least_bad_is_kept(self):
        state = tt.initial_state(6)
        for threads, rtf in ((3, 1.3), (2, 1.1), (1, 1.6), (4, 1.4)):
            state = run(state, 6, threads, rtf)
        self.assertEqual((state["threads"], state["settled"]), (2, True))
        self.assertAlmostEqual(state["baseline"], 1.1)

    def test_a_settled_choice_is_explored_again_only_when_clearly_worse(self):
        state = run(tt.initial_state(8), 8, 3, 0.6)
        state = run(state, 8, 3, 0.79)               # slower but still fast: stays
        self.assertTrue(state["settled"])
        state = run(state, 8, 3, 0.85)               # tight and above 0.6 + 0.15: measure again
        self.assertFalse(state["settled"])
        self.assertEqual(state["stats"], {"3": {"n": 1, "rtf": 0.85}})

    def test_tight_but_not_worse_than_chosen_stays_settled(self):
        state = tt.initial_state(6)
        for threads, rtf in ((3, 1.3), (2, 1.1), (1, 1.6), (4, 1.4)):
            state = run(state, 6, threads, rtf)
        state = run(state, 6, 2, 1.2)                # 1.2 is not above 1.1 + 0.15
        self.assertTrue(state["settled"])
        self.assertEqual(state["threads"], 2)

    def test_measurements_that_say_nothing_are_ignored(self):
        base = tt.initial_state(8)
        for kw in ({"steps": 5}, {"audio_seconds": 3.0}):
            self.assertEqual(run(base, 8, 3, 1.4, **kw), base)
        self.assertEqual(run(base, 8, 3, 0.0), base)
        self.assertEqual(run(base, 8, 3, -1.0), base)
        self.assertEqual(run(base, 8, 7, 1.4), base)

    def test_a_late_measurement_of_an_old_count_only_teaches_the_stats(self):
        state = run(tt.initial_state(8), 8, 3, 1.2)          # now trying 2
        later = run(state, 8, 3, 1.4)
        self.assertEqual(later["threads"], state["threads"])
        self.assertAlmostEqual(later["stats"]["3"]["rtf"], 1.3)
        self.assertEqual(later["stats"]["3"]["n"], 2)

    def test_the_input_state_is_never_modified(self):
        state = tt.initial_state(8)
        snapshot = json.dumps(state, sort_keys=True)
        run(state, 8, 3, 1.4)
        self.assertEqual(json.dumps(state, sort_keys=True), snapshot)

    def test_running_mean(self):
        state = tt.initial_state(8)
        for rtf in (1.0, 2.0, 3.0):
            state = run(state, 8, 3, rtf) if state["threads"] == 3 else state
        self.assertAlmostEqual(state["stats"]["3"]["rtf"], 1.0)   # only the first counted: it moved to 2


class SimulatedPhones(unittest.TestCase):
    """Phones whose true speed per thread count is known: does the tuner end on a good one?"""

    def phone(self, rng):
        cores = rng.choice([4, 6, 8])
        base = rng.uniform(0.5, 1.8)
        # speed per thread count: a random curve with its own best count
        best = rng.randint(1, min(4, cores))
        curve = {t: base * (1.0 + 0.35 * abs(t - best)) for t in range(1, min(4, cores) + 1)}
        return cores, curve

    def test_it_ends_on_a_count_near_the_best_and_never_moves_a_fast_phone(self):
        rng = random.Random(11)
        explored = 0
        for _ in range(300):
            cores, curve = self.phone(rng)
            state = tt.initial_state(cores)
            start = state["threads"]
            first = None
            for _session in range(12):
                threads = tt.threads_for(state, cores)
                rtf = curve[threads] * rng.uniform(0.97, 1.03)
                if first is None:
                    first = rtf
                state = tt.observe(state, cores, threads, rtf, 40, 20.0)
            final = tt.threads_for(state, cores)
            if first < tt.OK_RTF:
                self.assertEqual(final, start)                  # the first measurement was fast: never touched
            else:
                explored += 1
                self.assertLessEqual(curve[final], min(curve.values()) * 1.12 + 1e-9,
                                     (curve, final, state))     # within ~12% of the best true speed
        self.assertGreater(explored, 50)                        # the property was really exercised

    def test_exploration_is_short(self):
        rng = random.Random(5)
        for _ in range(200):
            cores, curve = self.phone(rng)
            state = tt.initial_state(cores)
            for session in range(1, 8):
                threads = tt.threads_for(state, cores)
                state = tt.observe(state, cores, threads, curve[threads], 40, 20.0)
                if state["settled"]:
                    self.assertLessEqual(session, len(tt.candidates(cores)))
                    break
            else:
                self.fail("never settled: %s" % (curve,))


class GoldenTests(unittest.TestCase):
    def test_fixture_is_current(self):
        path = os.path.join(ROOT, "test", "fixtures", "thread_tuner_golden.json")
        with open(path, encoding="utf-8") as handle:
            on_disk = json.load(handle)
        self.assertEqual(on_disk, json.loads(json.dumps(gen.build_tuner())),
                         "thread_tuner_golden.json is stale: run tools/frame_engine/gen_report_fixtures.py")


if __name__ == "__main__":
    unittest.main()
