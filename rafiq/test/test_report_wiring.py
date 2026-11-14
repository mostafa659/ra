import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


class TechnicalReportWiringTests(unittest.TestCase):
    """Guards the pieces of the technical report that are only connected by name."""

    def version(self) -> str:
        found = re.search(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+", read("pubspec.yaml"), re.M)
        self.assertIsNotNone(found)
        return found.group(1)

    def test_records_carry_the_version_in_pubspec(self):
        model = read("lib/core/audio_engine/report/tech_report_model.dart")
        self.assertIn("const String kReportAppVersion = '%s';" % self.version(), model)

    def test_workflow_artifacts_carry_the_version(self):
        workflow = read(".github/workflows/main.yml")
        self.assertIn("rafiq-v%s-arm64-apk" % self.version(), workflow)
        self.assertIn("rafiq-v%s-arm32-apk" % self.version(), workflow)

    def test_the_screen_shows_the_report_button_only_with_the_developer_diagnostics(self):
        screen = read("lib/features/memorize_engine/recitation_screen.dart")
        self.assertIn("import 'tech_report_screen.dart';", screen)
        call = "TechReportButton(controller: c)"
        self.assertEqual(screen.count(call), 1)
        before = screen[max(0, screen.index(call) - 220):screen.index(call)]
        self.assertIn("RAFIQ_ENABLE_TELEMETRY", before)

    def test_every_judged_ayah_reaches_the_report_and_the_log_with_schema_v3(self):
        controller = read("lib/features/memorize_engine/recitation_session_controller.dart")
        self.assertGreaterEqual(controller.count("_registerRecord(record)"), 2)
        self.assertIn("TechReportStore.instance.addRecord(record)", controller)
        self.assertIn("'v': 3,", controller)
        for key in ("'rid':", "'words': _wordRows()", "'wordMap':", "'flags':", "'cfg':", "'guard':"):
            self.assertIn(key, controller)
        # the evidence log still receives the record itself (test_engine_wiring checks the call)
        self.assertGreaterEqual(controller.count("EvidenceLog.append(record)"), 2)

    def test_labels_reach_the_evidence_log(self):
        controller = read("lib/features/memorize_engine/recitation_session_controller.dart")
        self.assertIn("TechReportStore.instance.evidenceSink", controller)
        store = read("lib/core/audio_engine/report/tech_report_store.dart")
        self.assertIn("sink(line)", store)
        self.assertIn("'kind': 'label'", read("lib/core/audio_engine/report/tech_report_model.dart"))

    def test_label_lines_never_push_records_out_of_the_copy_button(self):
        log = read("lib/core/audio_engine/evidence_log.dart")
        self.assertIn("selectTail(", log)
        self.assertIn('"kind":"label"', log)
        overlay = read("lib/features/memorize_engine/widgets/recitation_telemetry_overlay.dart")
        self.assertIn("EvidenceLog.tail(lines: 8)", overlay)

    def test_the_report_adds_no_dependency(self):
        pubspec = read("pubspec.yaml")
        for forbidden in ("share_plus", "open_filex", "flutter_sound", "sherpa_onnx"):
            self.assertNotIn(forbidden, pubspec)
        for path in ("tech_report_model.dart", "tech_report_store.dart", "wav_writer.dart", "report_export.dart"):
            source = read("lib/core/audio_engine/report/" + path)
            for imported in re.findall(r"^import 'package:([a-z_0-9]+)/", source, re.M):
                self.assertIn(imported, ("flutter", "path_provider", "file_picker", "rafiq_app"), path)

    def test_held_sound_ratio_is_measured_in_every_preset_in_both_languages(self):
        self.assertIn("MEASURE_MIN_RUNS = 3", read("tools/frame_engine/judge_ref.py"))
        self.assertIn("_measureMinRuns = 3", read("lib/core/audio_engine/frame/frame_judge.dart"))

    def test_the_next_ayah_waits_for_the_frame_judge_instead_of_discarding_it(self):
        controller = read("lib/features/memorize_engine/recitation_session_controller.dart")
        self.assertIn("_advanceWhenJudged(judging, epoch, fromAyah)", controller)
        self.assertIn("static const int _maxJudgeWaitMs = 2300;", controller)
        # every place that cancels the pause also cancels a pending wait for the judge
        self.assertNotIn("_advanceTimer?.cancel();", controller.replace(
            "void _cancelAdvance() {\n    _advanceTimer?.cancel();", ""))
        self.assertIn("epoch != _advanceEpoch", controller)
        # the old behaviour: a bare fixed timer that advanced regardless of the judge
        self.assertNotIn("Timer(const Duration(milliseconds: 1200), () {\n      if (_disposed) {", controller)

    def test_real_time_health_is_measured_with_the_models_own_step(self):
        controller = read("lib/features/memorize_engine/recitation_session_controller.dart")
        for key in ("_noteUpdate(update);", "'workerRtf':", "'lag': _lagStats.toJson()", "'eval': _evalStats.toJson()",
                    "'judge': _judgeStats.toJson()", "'judgeWaitMs':", "'backlogMax':", "'hopMs':",
                    "get telemetryHealth"):
            self.assertIn(key, controller)
        self.assertNotIn("/ 480.0", controller)       # the step is read from the model, never assumed
        engine = read("lib/core/audio_engine/frame/frame_ctc_engine.dart")
        self.assertEqual(engine.count("core.stepAudioMs"), 2)   # both update messages carry it
        self.assertIn("message.length > 13", engine)
        self.assertIn("double get stepAudioMs => model.hopFrames * 10.0;",
                      read("lib/core/audio_engine/frame/streaming_ctc_core.dart"))
        overlay = read("lib/features/memorize_engine/widgets/recitation_telemetry_overlay.dart")
        self.assertNotIn("لا توجد log_probs للإطارات", overlay)    # the frame judge uses them since 0.6.0

    def test_the_thread_count_follows_the_tuner_end_to_end(self):
        providers = read("lib/core/audio_engine/engine_providers.dart")
        self.assertIn("ThreadTunerStore.instance.threadsFor(Platform.numberOfProcessors)", providers)
        self.assertIn("threads: threads,", providers)
        engine = read("lib/core/audio_engine/frame/frame_ctc_engine.dart")
        self.assertIn("<Object>[events.sendPort, modelPath, tokensPath, _threadsUsed]", engine)
        self.assertIn("final int threads = args.length > 3 ? args[3] as int : 0;", engine)
        self.assertIn("classCountHint: table.classCount, threads: threads", engine)
        model = read("lib/core/audio_engine/frame/ort_chunk_model.dart")
        self.assertIn("setIntraOpNumThreads(threads > 0 ? threads :", model)
        controller = read("lib/features/memorize_engine/recitation_session_controller.dart")
        self.assertIn("_recordSpeed();", controller)
        self.assertIn("threadsUsed: engine.threadsUsed", controller)
        self.assertIn("'threads': engine.threadsUsed", controller)
        # a session reports its speed once, when it ends, and never from a half-run engine
        self.assertEqual(controller.count("_recordSpeed();"), 1)

    def test_the_golden_fixtures_and_their_dart_replays_exist(self):
        for path in ("test/fixtures/report_golden.json", "test/tech_report_model_test.dart",
                     "test/tech_report_store_test.dart", "test/wav_writer_test.dart", "test/evidence_log_test.dart",
                     "test/latency_stats_test.dart", "test/thread_tuner_test.dart",
                     "test/fixtures/thread_tuner_golden.json"):
            self.assertTrue((ROOT / path).exists(), path)


if __name__ == "__main__":
    unittest.main()
