"""Exercise programming log checks without ripgrep or physical hardware."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class SyncIrisTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="iris-sync-tests-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        tools = self.directory / "bin"
        tools.mkdir()
        for name in ("bash", "dirname", "readlink", "mktemp", "tee", "grep", "rm"):
            executable = shutil.which(name)
            self.assertIsNotNone(executable, f"Missing test dependency: {name}")
            (tools / name).symlink_to(executable)
        (tools / "python3").symlink_to(sys.executable)

        efinity = self.directory / "efinity"
        (efinity / "bin").mkdir(parents=True)
        (efinity / "bin/setup.sh").write_text(
            'efx_run() {\n'
            '    for argument in "$@"; do\n'
            '        if [[ "$argument" == source=* ]]; then return 0; fi\n'
            '    done\n'
            '    printf "%s\\n" "$IRIS_TEST_PROGRAM_OUTPUT"\n'
            '    return "$IRIS_TEST_PROGRAM_STATUS"\n'
            '}\n'
        )
        bridge = self.directory / "bridge.bit"
        bridge.touch()
        project = self.directory / "project"
        (project / "outflow").mkdir(parents=True)
        (project / "outflow/iris_ws.timing.rpt").write_text(
            "Setup (Max) Clock Relationship\n"
            "core_clk core_clk 5.000 0.027 (R-R)\n"
            "Hold (Min) Clock Relationship\n"
            "core_clk core_clk 0.000 0.025 (R-R)\n"
            "NOTE:\n"
        )
        self.environment = {
            **os.environ,
            "PATH": str(tools),
            "EFINITY_HOME": str(efinity),
            "IRIS_PROJ_DIR": str(project),
            "IRIS_BRIDGE_BIT": str(bridge),
            "TMPDIR": str(self.directory),
        }
        self.environment.pop("BASH_ENV", None)
        self.assertIsNone(shutil.which("rg", path=str(tools)))

    def run_program(self, mode, output, status=0):
        arguments = [str(ROOT / ".script/sync-iris")]
        if mode is not None:
            arguments.append(mode)
        return subprocess.run(
            arguments,
            env={
                **self.environment,
                "IRIS_TEST_PROGRAM_OUTPUT": output,
                "IRIS_TEST_PROGRAM_STATUS": str(status),
            },
            capture_output=True,
            text=True,
            timeout=10,
        )

    def test_flash_verification_without_ripgrep(self):
        success = "Flash verify successful\nJTAG2SPI programming...done"
        failure = "ERROR: Flash verify unsuccessful... mismatch found"
        cases = (
            (success, 0, 0),
            (failure + "\nretry program using max clk ...\n" + success, 0, 0),
            (failure, 0, 1),
            ("JTAG2SPI programming...done", 0, 1),
            (success, 9, 1),
        )
        for mode in (None, "jtag_bridge", "jtag_bridge_x8"):
            for output, status, expected in cases:
                with self.subTest(mode=mode, output=output, status=status):
                    previous_logs = set(self.directory.glob("iris-flash-program.*"))
                    result = self.run_program(mode, output, status)
                    self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                    self.assertEqual("烧录完成" in result.stdout, expected == 0)
                    self.assertEqual("请断电重上电" in result.stdout, expected == 0)
                    logs = set(self.directory.glob("iris-flash-program.*")) - previous_logs
                    self.assertEqual(len(logs), expected)
                    for log in logs:
                        self.assertEqual(log.read_text(), output + "\n")
                        log.unlink()

    def test_sram_does_not_require_flash_verification(self):
        result = self.run_program("jtag", "... finished with JTAG programming")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("烧录完成", result.stdout)
        self.assertNotIn("请断电重上电", result.stdout)
        self.assertEqual(list(self.directory.glob("iris-flash-program.*")), [])


if __name__ == "__main__":
    unittest.main()
