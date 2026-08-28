#!/usr/bin/env python3
"""Regenerate final final/Resources/Export/reference.odt with hand-tuned styles.

Pandoc round-trips styles.xml from the ODT passed as --reference-doc into the
exported document, so the checked-in reference.odt only needs one file edited
to gain DOCX-matching fonts, heading sizes, and spacing: styles.xml. Everything
else in the archive (content.xml, meta.xml, manifest.rdf, META-INF/manifest.xml,
mimetype) comes straight from the existing reference.odt, untouched.

This script:
  1. Unpacks the existing reference.odt into a temp directory.
  2. Replaces its styles.xml with the hand-tuned version checked in alongside
     this script (scripts/reference-odt/styles.xml).
  3. Re-zips the result back over final final/Resources/Export/reference.odt.

ODF requires the "mimetype" entry to be first in the zip archive and stored
*uncompressed* (this is how a file-type sniffer identifies an ODF package
without inflating the whole archive). Every other entry is written with normal
DEFLATE compression, matching how the original reference.odt was packed.

Usage:
    python3 scripts/reference-odt/build-reference-odt.py

Run this after editing scripts/reference-odt/styles.xml, and before running
ReferenceOdtStyleParityTests (which asserts against the committed
reference.odt, not against styles.xml directly).
"""
from __future__ import annotations

import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
REFERENCE_ODT = REPO_ROOT / "final final" / "Resources" / "Export" / "reference.odt"
STYLES_XML = Path(__file__).resolve().parent / "styles.xml"


def main() -> int:
    if not REFERENCE_ODT.exists():
        print(f"error: reference.odt not found at {REFERENCE_ODT}", file=sys.stderr)
        return 1
    if not STYLES_XML.exists():
        print(
            f"error: hand-tuned styles.xml not found at {STYLES_XML}",
            file=sys.stderr,
        )
        return 1

    with tempfile.TemporaryDirectory(prefix="reference-odt-build-") as tmp:
        tmp_path = Path(tmp)
        extract_dir = tmp_path / "unpacked"
        extract_dir.mkdir()

        with zipfile.ZipFile(REFERENCE_ODT) as zf:
            names = zf.namelist()
            if "mimetype" not in names:
                print(
                    "error: reference.odt has no mimetype entry; refusing to touch it",
                    file=sys.stderr,
                )
                return 1
            zf.extractall(extract_dir)

        # Replace styles.xml with the hand-tuned, checked-in version.
        shutil.copyfile(STYLES_XML, extract_dir / "styles.xml")

        # Re-zip: mimetype first and STORED (uncompressed), everything else
        # DEFLATED, preserving the original archive's member order otherwise.
        rest = [name for name in names if name != "mimetype"]

        tmp_odt = tmp_path / "reference.odt"
        with zipfile.ZipFile(tmp_odt, "w") as zf:
            zf.write(
                extract_dir / "mimetype",
                "mimetype",
                compress_type=zipfile.ZIP_STORED,
            )
            for name in rest:
                zf.write(extract_dir / name, name, compress_type=zipfile.ZIP_DEFLATED)

        shutil.copyfile(tmp_odt, REFERENCE_ODT)

    print(f"Wrote {REFERENCE_ODT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
