#!/usr/bin/env python3
"""Load the approved ambiguity taxonomy and refuse anything it does not name.

The mapping is a lookup on the raw kind string and nothing else — no transcript, no
reviewer wording. That is what makes it safe to apply mechanically, and it is also why an
unknown raw kind has to stop the run rather than fall through to `other`: `other` is a
judgment a reviewer's proposal was approved for, not a default for something nobody looked
at.
"""

import hashlib
import json
from pathlib import Path

SCHEMA_VERSION = "ambiguity-taxonomy-v0.1"
CONFIDENCE_LEVELS = ("high", "medium", "low")


class TaxonomyError(RuntimeError):
    """A mapping problem that must stop normalization rather than guess a category."""


class AmbiguityTaxonomy:
    def __init__(self, config, digest):
        self.config = config
        self.digest = digest
        self.mappings = config["mappings"]
        self.taxonomy = tuple(config["taxonomy"])

    @classmethod
    def load(cls, path, expected_sha256=None):
        path = Path(path)
        raw = path.read_bytes()
        digest = hashlib.sha256(raw).hexdigest()
        if expected_sha256 is not None and digest != expected_sha256:
            raise TaxonomyError(
                "taxonomy config digest mismatch: {} expected, {} found".format(
                    expected_sha256, digest
                )
            )
        config = json.loads(raw.decode("utf-8"))
        if config.get("schema_version") != SCHEMA_VERSION:
            raise TaxonomyError("taxonomy config is not {}".format(SCHEMA_VERSION))
        mappings = config.get("mappings")
        if not isinstance(mappings, dict) or not mappings:
            raise TaxonomyError("taxonomy config has no mappings")
        allowed = set(config.get("taxonomy") or ())
        if not allowed:
            raise TaxonomyError("taxonomy config declares no categories")
        for raw_kind, entry in mappings.items():
            if not isinstance(entry, dict):
                raise TaxonomyError("{} mapping is not an object".format(raw_kind))
            if entry.get("taxonomy") not in allowed:
                raise TaxonomyError(
                    "{} maps to a category outside the approved list: {}".format(
                        raw_kind, entry.get("taxonomy")
                    )
                )
            if not str(entry.get("reason") or "").strip():
                raise TaxonomyError("{} mapping has no reason".format(raw_kind))
            if entry.get("confidence") not in CONFIDENCE_LEVELS:
                raise TaxonomyError("{} mapping has an unknown confidence".format(raw_kind))
        return cls(config, digest)

    def classify(self, raw_kind):
        """Return the approved category, or refuse. A new kind is never assumed."""
        entry = self.mappings.get(raw_kind)
        if entry is None:
            raise TaxonomyError(
                "raw ambiguity kind is not in the approved mapping: {}".format(raw_kind)
            )
        return entry["taxonomy"]

    def coverage(self, raw_kinds):
        """Every raw kind present in the data must be mapped, exactly once each."""
        unmapped = sorted({kind for kind in raw_kinds if kind not in self.mappings})
        if unmapped:
            raise TaxonomyError("unmapped raw ambiguity kinds: {}".format(unmapped))
        return {kind: self.mappings[kind]["taxonomy"] for kind in sorted(set(raw_kinds))}
