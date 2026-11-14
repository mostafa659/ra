import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools", "frame_engine"))
import lexicon_align_ref as la  # noqa: E402

FA, KASRA, DAMMA = "\u064e", "\u0650", "\u064f"


class AlignTests(unittest.TestCase):
    def test_every_text_word_gets_a_piece_and_nothing_is_lost(self):
        lex = ["و" + FA + "ل" + FA + "ا", "ي" + FA + "ك" + DAMMA + "و" + "ن" + DAMMA]
        text = [1, 2, 4]
        out = la.align(lex, text)
        self.assertEqual(len(out), 3)
        self.assertTrue(all(out))
        self.assertEqual("".join(out), "".join(lex))

    def test_merged_proclitic_is_split_on_a_unit_boundary(self):
        lex = ["و" + FA + "ل" + FA + "ا", "ي" + FA + "ك" + DAMMA + "ن" + DAMMA]
        out = la.align(lex, [1, 2, 3])
        self.assertEqual(out[0], "و" + FA)
        self.assertEqual(out[1], "ل" + FA + "ا")
        # a mark never starts a piece
        for piece in out:
            self.assertFalse(la._is_mark(piece[0]))

    def test_old_mapping_left_a_short_word_empty_and_the_new_one_does_not(self):
        lex = ["ك" + FA + "ت" + FA + "ب" + FA + "ن" + FA + "ا", "م" + FA + "ا" + "ل" + FA + "ك" + FA]
        text = [4, 1, 5]  # a one-letter word between two long ones
        old = la.old_align(lex, text)
        self.assertIn("", old)
        new = la.align(lex, text)
        self.assertTrue(all(new))
        self.assertEqual("".join(new), "".join(lex))

    def test_lexicon_boundary_is_preferred_when_positions_are_close(self):
        lex = ["ا" + KASRA + "ن", "ن" + FA + "ا", "ر" + FA + "ب" + FA]
        out = la.align(lex, [3, 2, 3])
        self.assertEqual(out, lex)

    def test_more_text_words_than_units_gives_none(self):
        self.assertIsNone(la.align(["ب" + FA], [1, 1]))

    def test_single_word(self):
        self.assertEqual(la.align(["ب" + FA, "ت" + FA], [5]), ["ب" + FA + "ت" + FA])


if __name__ == "__main__":
    unittest.main()
