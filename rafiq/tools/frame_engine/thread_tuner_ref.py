"""Reference for lib/core/audio_engine/frame/thread_tuner.dart.

Why: how many threads ONNX Runtime should use for the streaming model depends on
the phone (big.LITTLE cores, thermal limits, what else runs), and the fixed guess
in ort_chunk_model.dart (3 threads from 6 cores up, else 2) cannot know. The
engine already measures what matters: the time it spends per second of audio
(workerRtf in the evidence record, see report_ref.perf_health). This tuner turns
that measurement into the thread count of the NEXT engine start, by hill-climbing
across sessions, with no effort from the person:

  * while the phone is fast (rtf < OK_RTF) nothing ever changes;
  * when it is tight or slow, the neighbouring counts not yet measured are tried
    one per session (fewer threads first: big.LITTLE phones often prefer fewer)
    until one is comfortably fast (rtf < COMFORT_RTF: a phone that only just
    clears the limit is one load spike away from lagging) or every candidate was
    measured; then the best measured one is kept;
  * a settled choice is explored again only when it gets clearly worse.

The state is plain JSON (threads, stats, settled, baseline). Everything here is a
pure function of (state, measurement); the Dart port is pinned by
test/fixtures/thread_tuner_golden.json.
"""
import copy

OK_RTF = 0.8            # at or above this the phone is "tight" (report_ref.RTF_TIGHT)
COMFORT_RTF = 0.6       # once exploring, keep looking until a count is this fast (or all were measured)
RETRY_MARGIN = 0.15     # a settled choice that gets this much worse than when chosen is explored again
MIN_STEPS = 10          # a session shorter than this says nothing about speed
MIN_AUDIO_SECONDS = 8.0
MAX_THREADS = 4


def candidates(cores):
    """Thread counts worth trying on a phone with `cores` cores."""
    top = max(1, min(MAX_THREADS, int(cores)))
    return list(range(1, top + 1))


def default_threads(cores):
    """The shipped guess, kept as the starting point (3 from 6 cores up, else 2)."""
    guess = 3 if cores >= 6 else 2
    return min(guess, candidates(cores)[-1])


def initial_state(cores):
    return {"threads": default_threads(cores), "stats": {}, "settled": False, "baseline": 0.0}


def _by_closeness(current, options):
    """Untried counts nearest to `current` first; at equal distance fewer threads first."""
    return sorted(options, key=lambda t: (abs(t - current), t))


def observe(state, cores, threads_used, rtf, steps, audio_seconds):
    """The state after one finished session that ran with `threads_used` threads.

    rtf: engine busy time / audio time of that session (1.0 = falls a second
    further behind every second). Returns a new dict; `state` is not modified.
    """
    s = copy.deepcopy(state)
    options = candidates(cores)
    if (steps < MIN_STEPS or audio_seconds < MIN_AUDIO_SECONDS or rtf <= 0.0
            or threads_used not in options):
        return s
    entry = s["stats"].setdefault(str(threads_used), {"n": 0, "rtf": 0.0})
    entry["rtf"] = (entry["rtf"] * entry["n"] + rtf) / (entry["n"] + 1)
    entry["n"] += 1
    if threads_used != s["threads"]:
        return s          # measured with a count that is no longer the chosen one: only the stats learn from it

    if s["settled"]:
        if rtf >= OK_RTF and rtf > s["baseline"] + RETRY_MARGIN:
            # conditions changed (a hotter phone, a new background load): measure again from here
            s["settled"] = False
            s["stats"] = {str(threads_used): {"n": 1, "rtf": rtf}}
            entry = s["stats"][str(threads_used)]
        else:
            return s

    explored = len(s["stats"]) > 1
    if entry["rtf"] < (COMFORT_RTF if explored else OK_RTF):
        s["settled"] = True
        s["baseline"] = entry["rtf"]
        return s
    untried = [t for t in options if str(t) not in s["stats"]]
    if untried:
        s["threads"] = _by_closeness(threads_used, untried)[0]
        return s
    best = min(options, key=lambda t: (s["stats"][str(t)]["rtf"], t))
    s["threads"] = best
    s["settled"] = True
    s["baseline"] = s["stats"][str(best)]["rtf"]
    return s


def threads_for(state, cores):
    """What the next engine start should use (a stored value is clamped to this phone)."""
    options = candidates(cores)
    value = int(state.get("threads", default_threads(cores)))
    return value if value in options else default_threads(cores)
