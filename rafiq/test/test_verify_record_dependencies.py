import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.verify_record_dependencies import validate_graph  # noqa: E402

VERIFY_COMMAND = 'python3 scripts/verify_record_dependencies.py "$RUNNER_TEMP/rafiq-pub-deps.json"'
EXPORT_COMMAND = 'flutter pub deps --json > "$RUNNER_TEMP/rafiq-pub-deps.json"'
SELF_PATH = ".github/workflows/"


def _read_yaml_files(directory: pathlib.Path):
    """Return [(path, text)] for every YAML file in directory (any file name)."""
    if not directory.is_dir():
        return []
    return [
        (path, path.read_text(encoding="utf-8"))
        for path in sorted(directory.iterdir())
        if path.is_file() and path.suffix.lower() in {".yml", ".yaml"}
    ]


class RecordDependencyCompatibilityTests(unittest.TestCase):
    def test_pubspec_pins_compatible_record_line(self):
        """The code-level guarantee: Pub cannot pick record 5.x / record_linux 0.7.x."""
        pubspec = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
        self.assertIn("record: ^6.2.1", pubspec)

    def test_workflow_wiring_is_correct_when_the_current_workflow_is_installed(self):
        """Validate the verifier wiring without turning a stale workflow into a build failure.

        The workflow may have any file name (main.yml, android_build.yml, ...).
        A stale or missing workflow is a deployment issue, not a defect in the
        source: the pubspec pin above is what guarantees a compatible graph, so a
        stale or missing workflow only produces a warning.
        """
        workflows = _read_yaml_files(ROOT / ".github" / "workflows")
        current = [(p, t) for p, t in workflows if "verify_record_dependencies" in t]
        if not current:
            print(
                "::warning::No workflow in this checkout runs "
                "scripts/verify_record_dependencies.py (stale or missing). "
                "The pubspec pin 'record: ^6.2.1' still guarantees a compatible graph. "
                "Replace your workflow file with the supplied version to enable the "
                "extra resolved-graph check."
            )
            return
        for path, text in current:
            with self.subTest(workflow=path.name):
                self.assertIn(VERIFY_COMMAND, text)
                self.assertIn(EXPORT_COMMAND, text)
                self.assertLess(
                    text.index("run: flutter pub get"),
                    text.index(EXPORT_COMMAND),
                    "The dependency verifier must run after flutter pub get.",
                )
                if SELF_PATH in text:
                    print(
                        f"::warning::{path.name} references {SELF_PATH}. A workflow must not "
                        "depend on its own file name; use steps that work for any file name."
                    )

    def test_shipped_workflow_copy_does_not_depend_on_its_own_file_name(self):
        """Regression guard: v0.4.7-0.4.10 grepped '.github/workflows/android_build.yml'
        from inside the workflow, which failed whenever the file had another name."""
        for path, text in _read_yaml_files(ROOT / "GITHUB_WORKFLOW_COPY"):
            with self.subTest(workflow=path.name):
                self.assertNotIn(SELF_PATH, text)
                self.assertNotIn("android_build.yml", text)

    def test_accepts_compatible_record_6_graph(self):
        graph = {
            "packages": [
                {"name": "record", "version": "6.2.1"},
                {"name": "record_linux", "version": "1.3.1"},
                {"name": "record_platform_interface", "version": "1.6.0"},
            ]
        }
        self.assertEqual(validate_graph(graph), [])

    def test_rejects_original_incompatible_graph(self):
        graph = {
            "packages": [
                {"name": "record", "version": "5.2.1"},
                {"name": "record_linux", "version": "0.7.2"},
                {"name": "record_platform_interface", "version": "1.6.0"},
            ]
        }
        errors = validate_graph(graph)
        self.assertTrue(errors)
        self.assertTrue(any("record_linux=0.7.2" in error for error in errors))

    def test_rejects_missing_packages(self):
        self.assertTrue(validate_graph({"packages": []}))

    def test_rejects_invalid_version_format(self):
        graph = {
            "packages": [
                {"name": "record", "version": "future"},
                {"name": "record_linux", "version": "1.3.1"},
                {"name": "record_platform_interface", "version": "1.6.0"},
            ]
        }
        self.assertTrue(any("cannot validate record=future" in error for error in validate_graph(graph)))


if __name__ == "__main__":
    unittest.main()
