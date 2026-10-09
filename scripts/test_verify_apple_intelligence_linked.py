import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("verify-apple-intelligence-linked.sh")


class VerifyAppleIntelligenceLinkedTests(unittest.TestCase):
    def run_script(self, otool_output, create_executable=True):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stub = root / "bin" / "otool"
            stub.parent.mkdir()
            stub.write_text(f"#!/bin/bash\ncat <<'EOF'\n{otool_output}\nEOF\n")
            stub.chmod(stub.stat().st_mode | stat.S_IEXEC)
            executable = root / "OpenWritr"
            if create_executable:
                executable.write_bytes(b"binary")
            environment = {**os.environ, "PATH": f"{stub.parent}:{os.environ['PATH']}"}
            return subprocess.run(
                ["bash", str(SCRIPT), str(executable)],
                capture_output=True,
                text=True,
                env=environment,
            )

    def test_accepts_an_executable_linking_foundation_models(self):
        result = self.run_script(
            "/x/OpenWritr:\n"
            "\t/System/Library/Frameworks/FoundationModels.framework/Versions/A/FoundationModels (weak)"
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_an_executable_built_without_the_sdk(self):
        result = self.run_script(
            "/x/OpenWritr:\n\t/System/Library/Frameworks/Foundation.framework/Foundation"
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("Apple Intelligence was compiled out", result.stderr)

    def test_rejects_a_missing_executable(self):
        result = self.run_script("", create_executable=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("Executable not found", result.stderr)


if __name__ == "__main__":
    unittest.main()
