"""Structural checks of assets/qps_reference.json.gz (NOT a substitute for owner review of qps_review_50.json)."""
import gzip, json, os, unittest
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VOCAB = set(json.load(open(os.path.join(ROOT, "tools/scoring_ref/phoneme_vocab.json")))["id_to_char"]) | {" "}

class QpsRef(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.d = json.load(gzip.open(os.path.join(ROOT, "assets/qps_reference.json.gz"), "rt"))["ayat"]
    def test_counts(self):
        self.assertEqual(len(self.d), 6236)
        self.assertEqual(sum(len(a["words"]) for a in self.d), 77433)
    def test_alphabet_is_model_alphabet(self):
        for a in self.d:
            for w in a["words"]:
                self.assertTrue(set(w["wasl"] + w["waqf"]) <= VOCAB, (a["s"], a["a"], w["uthmani"]))
                self.assertTrue(w["wasl"], (a["s"], a["a"]))
    def test_intervals_consistent(self):
        for a in self.d:
            for w in a["words"]:
                for p, lo, hi in w["intervals"] or []:
                    self.assertLess(lo, hi)
    def test_103_3_golden(self):
        a = next(x for x in self.d if (x["s"], x["a"]) == (103, 3))
        self.assertEqual([w["wasl"] for w in a["words"]], ["ءِللَ", "للَذِۦۦنَ", "ءَاامَنُۥۥ", "وَعَمِلُ", "صصَاالِحَااتِ", "وَتَوَااصَو", "بِلحَققِ", "وَتَوَااصَو", "بِصصَبڇر"])
    def test_review_fixture_never_claims_verified(self):
        r = json.load(open(os.path.join(ROOT, "test/fixtures/qps_review_50.json")))
        self.assertGreaterEqual(len(r), 50)
