import unittest

import extract_release_notes


class ExtractReleaseNotesTests(unittest.TestCase):
    def test_extracts_build_metadata_version_literally(self) -> None:
        changelog = """# Changelog

## [1.2.3+build.1] — 2026-09-22

### Fixed
- Preserved build metadata.

## [1.2.3buildX1] — 2026-09-21

- Must not match regex metacharacters.
"""
        self.assertEqual(
            extract_release_notes.extract_release_notes(
                changelog,
                "1.2.3+build.1",
            ),
            "### Fixed\n- Preserved build metadata.\n",
        )

    def test_rejects_entries_left_under_unreleased(self) -> None:
        changelog = """# Changelog

## Unreleased

- Not promoted.

## [1.2.3+build.1]

- Release notes.
"""
        with self.assertRaisesRegex(ValueError, "still holds entries"):
            extract_release_notes.extract_release_notes(
                changelog,
                "1.2.3+build.1",
            )

    def test_rejects_missing_release_section(self) -> None:
        with self.assertRaisesRegex(ValueError, "no non-empty entry"):
            extract_release_notes.extract_release_notes(
                "# Changelog\n\n## [1.2.4]\n\n- Other release.\n",
                "1.2.3+build.1",
            )


if __name__ == "__main__":
    unittest.main()
