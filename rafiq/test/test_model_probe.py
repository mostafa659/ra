import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("model_probe", ROOT / "tools" / "model_probe.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class ModelProbeHelperTests(unittest.TestCase):
    def test_family_strips_only_the_layer_index(self):
        self.assertEqual(probe.family("cached_key_12"), "cached_key")
        self.assertEqual(probe.family("cached_embed_left_pad"), "cached_embed_left_pad")
        self.assertEqual(probe.family("processed_lens"), "processed_lens")

    def test_state_families_skip_the_feature_input(self):
        inputs = [
            {"name": "x"},
            {"name": "cached_len_0"},
            {"name": "cached_len_1"},
            {"name": "processed_lens"},
        ]
        self.assertEqual(
            dict(probe.summarize_inputs(inputs)),
            {"cached_len": 2, "processed_lens": 1},
        )

    def test_outputs_are_paired_by_new_prefix_when_present(self):
        ins = ["x", "cached_len_0", "processed_lens"]
        outs = ["log_probs", "new_cached_len_0", "new_processed_lens"]
        mapping = probe.map_outputs(ins, outs)
        self.assertEqual(mapping["by"], "name")
        self.assertEqual(mapping["pairs"]["processed_lens"], "new_processed_lens")

    def test_position_fallback_is_flagged_as_a_guess(self):
        mapping = probe.map_outputs(["x", "a_0"], ["log_probs", "zzz"])
        self.assertIn("GUESS", mapping["by"])
        self.assertEqual(mapping["pairs"], {"a_0": "zzz"})

    def test_dynamic_dimensions_become_one(self):
        self.assertEqual(probe.concrete_shape(["N", 61, 80]), [1, 61, 80])
        self.assertEqual(probe.concrete_shape([None, 3]), [1, 3])

    def test_dtype_table(self):
        self.assertEqual(probe.numpy_dtype("tensor(int64)"), "int64")
        self.assertEqual(probe.numpy_dtype("tensor(float)"), "float32")


if __name__ == "__main__":
    unittest.main()
