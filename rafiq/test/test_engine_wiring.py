import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


class RecitationEngineWiringTests(unittest.TestCase):
    """Guards against re-introducing the tolerant matching that hid mistakes."""

    def test_session_controller_uses_only_the_strict_evaluator(self):
        controller = read("lib/features/memorize_engine/recitation_session_controller.dart")
        self.assertIn("StrictRecitationEvaluator(", controller)
        self.assertNotIn("RecitationEvaluator(", controller.replace("StrictRecitationEvaluator(", ""))
        self.assertNotIn("acceptRatio", controller)

    def test_strict_evaluator_has_no_ratio_threshold(self):
        evaluator = read("lib/core/audio_engine/strict_recitation_evaluator.dart")
        self.assertNotIn("acceptRatio", evaluator)
        self.assertNotIn("0.25", evaluator)
        self.assertNotIn("0.38", evaluator)

    def test_recognizer_is_flushed_when_listening_stops(self):
        controller = read("lib/features/memorize_engine/recitation_session_controller.dart")
        engine = read("lib/core/audio_engine/frame/frame_ctc_engine.dart")
        self.assertIn("finishAndWait()", controller)
        self.assertIn("command == 'finish'", engine)
        self.assertIn("Float32List(19200)", engine)

    def test_endpointing_stays_disabled(self):
        engine = read("lib/core/audio_engine/frame/frame_ctc_engine.dart")
        self.assertIn("false, activeSessionId", engine)  # endpoint flag is always false
        self.assertNotIn("isEndpoint", engine)

    def test_sherpa_is_gone_and_onnxruntime_is_the_only_runtime(self):
        pubspec = read("pubspec.yaml")
        self.assertNotIn("sherpa_onnx:", pubspec)
        self.assertIn("onnxruntime_v2:", pubspec)
        self.assertFalse((ROOT / "lib/core/audio_engine/sherpa_tajweed_engine.dart").exists())

    def test_frame_judge_results_are_applied_and_logged(self):
        controller = read("lib/features/memorize_engine/recitation_session_controller.dart")
        self.assertIn("engine.judgeFrames(", controller)
        self.assertIn("_applyFrameFinding(", controller)
        self.assertIn("_judgeAndRecord(complete: true)", controller)
        self.assertIn("_judgeAndRecord(complete: false)", controller)
        self.assertIn("record['frames']", controller)

    def test_dart_test_for_the_evaluator_is_present(self):
        test = read("test/strict_recitation_evaluator_test.dart")
        self.assertIn("StrictRecitationEvaluator", test)
        self.assertIn("perfect recitation", test)

    def test_approximate_reference_never_yields_a_verified_correct_word(self):
        evaluator = read("lib/core/audio_engine/strict_recitation_evaluator.dart")
        self.assertIn("!canonicalReference && verdict == WordVerdict.correct", evaluator)
        self.assertIn("verdict = WordVerdict.uncertain;", evaluator)

    def test_every_judged_ayah_is_written_to_the_evidence_log(self):
        controller = read("lib/features/memorize_engine/recitation_session_controller.dart")
        self.assertIn("EvidenceLog.append", controller)
        self.assertIn("_recordEvidence(complete: false)", controller)
        log = read("lib/core/audio_engine/evidence_log.dart")
        self.assertIn("rafiq_evidence.jsonl", log)

    def test_user_facing_text_does_not_claim_every_difference_is_caught(self):
        screen = read("lib/features/memorize_engine/recitation_screen.dart")
        controller = read("lib/features/memorize_engine/recitation_session_controller.dart")
        for text in (screen, controller):
            self.assertNotIn("يُعلَّم كل اختلاف في الحرف", text)
        self.assertIn("الإخفاء والغنة والقلقلة", screen)


if __name__ == "__main__":
    unittest.main()
