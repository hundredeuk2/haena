#!/usr/bin/env python3
"""Tests for the approved ambiguity taxonomy config.

Run with `python3 -m unittest discover -s scripts/benchmarks -p 'test_*.py'`.

The config is the one place where a raw kind becomes a category, so the tests are about
what it refuses: an unknown kind, a category outside the approved list, a digest that does
not match the one the normalizer was told to expect.
"""

import hashlib
import json
import sys
import tempfile
import unittest
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ambiguity_taxonomy as taxonomy  # noqa: E402  (import path is set above)

CONFIG_PATH = Path(__file__).resolve().parent / "ambiguity-taxonomy-v0.1.json"
REVIEW_ROOT = Path("data/benchmarks/haena-v0/meeting-execution-v0/human-reviews/primary")

# The distribution measured from the sixteen completed reviews. The approved summary table
# added to 65 rather than 68: `commitment_scope` is ten raw kinds totalling twelve
# ambiguities, and `historical_vs_new` is four kinds of one each. The per-kind mapping the
# summary was derived from is unchanged.
APPROVED_DISTRIBUTION = {
    "window_boundary": 21,
    "commitment_scope": 12,
    "metadata_mismatch": 5,
    "output_category": 5,
    "evidence_quality": 4,
    "historical_vs_new": 4,
    "question_resolution": 3,
    "due_or_time": 3,
    "prior_state_identity": 2,
    "other": 6,
    "procedural_vs_substantive": 1,
    "speaker_or_actor_identity": 1,
    "assignee_scope": 1,
}


class TaxonomyConfigTests(unittest.TestCase):
    def setUp(self):
        self.taxonomy = taxonomy.AmbiguityTaxonomy.load(CONFIG_PATH)

    def test_the_config_maps_forty_four_raw_kinds_exactly_once(self):
        mappings = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))["mappings"]
        self.assertEqual(len(mappings), 44)
        self.assertEqual(len(set(mappings)), 44)

    def test_every_category_is_from_the_approved_list(self):
        allowed = set(self.taxonomy.taxonomy)
        self.assertEqual(len(allowed), 13)
        for raw_kind, entry in self.taxonomy.mappings.items():
            self.assertIn(entry["taxonomy"], allowed, raw_kind)

    def test_other_is_used_for_exactly_the_six_approved_kinds(self):
        others = sorted(k for k, v in self.taxonomy.mappings.items() if v["taxonomy"] == "other")
        self.assertEqual(others, [
            "actor_and_action_state",
            "conditional_answer_correction",
            "contested_procurement_motive",
            "evaluation_vs_reporting_compliance",
            "selection_limit_vs_reported_expansion",
            "two_document_scope",
        ])

    def test_the_two_adjusted_mappings_are_recorded(self):
        self.assertEqual(
            self.taxonomy.classify("agenda_item_number_conflict"), "evidence_quality"
        )
        self.assertEqual(
            self.taxonomy.classify("unfinished_agenda_disposition"), "output_category"
        )

    def test_an_unknown_raw_kind_stops_rather_than_becoming_other(self):
        with self.assertRaises(taxonomy.TaxonomyError):
            self.taxonomy.classify("something_nobody_proposed")
        with self.assertRaises(taxonomy.TaxonomyError):
            self.taxonomy.coverage(["truncated_window_end", "something_nobody_proposed"])

    def test_a_digest_mismatch_refuses_the_config(self):
        with self.assertRaises(taxonomy.TaxonomyError):
            taxonomy.AmbiguityTaxonomy.load(CONFIG_PATH, expected_sha256="f" * 64)
        digest = hashlib.sha256(CONFIG_PATH.read_bytes()).hexdigest()
        self.assertEqual(taxonomy.AmbiguityTaxonomy.load(CONFIG_PATH, digest).digest, digest)

    def test_a_category_outside_the_approved_list_refuses_the_config(self):
        broken = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        broken["mappings"]["truncated_window_end"]["taxonomy"] = "invented_category"
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "broken.json"
            path.write_text(json.dumps(broken, ensure_ascii=False), encoding="utf-8")
            with self.assertRaises(taxonomy.TaxonomyError):
                taxonomy.AmbiguityTaxonomy.load(path)

    def test_a_mapping_without_a_reason_refuses_the_config(self):
        broken = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        broken["mappings"]["truncated_window_end"]["reason"] = ""
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "broken.json"
            path.write_text(json.dumps(broken, ensure_ascii=False), encoding="utf-8")
            with self.assertRaises(taxonomy.TaxonomyError):
                taxonomy.AmbiguityTaxonomy.load(path)


@unittest.skipUnless(REVIEW_ROOT.is_dir(), "local corpus is not present")
class TaxonomyCoverageTests(unittest.TestCase):
    def raw_kinds(self):
        kinds = []
        for path in sorted(REVIEW_ROOT.glob("MEV0-*.review.json")):
            for item in json.loads(path.read_text(encoding="utf-8"))["ambiguities"]:
                kinds.append(item["kind"])
        return kinds

    def test_every_recorded_ambiguity_is_mapped(self):
        kinds = self.raw_kinds()
        self.assertEqual(len(kinds), 68)
        mapped = taxonomy.AmbiguityTaxonomy.load(CONFIG_PATH).coverage(kinds)
        self.assertEqual(len(mapped), 44)

    def test_the_distribution_matches_the_approved_mapping(self):
        table = taxonomy.AmbiguityTaxonomy.load(CONFIG_PATH)
        counts = Counter(table.classify(kind) for kind in self.raw_kinds())
        self.assertEqual(dict(counts), APPROVED_DISTRIBUTION)
        self.assertEqual(sum(counts.values()), 68)
        self.assertEqual(counts["other"], 6)


if __name__ == "__main__":
    unittest.main()
