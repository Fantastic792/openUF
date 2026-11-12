import os
import subprocess
import tempfile
import unittest
from unittest import mock

from labtest import target

CONF = {"ssh_key": "/k/id_test", "targets": {"vm1": {"host": "198.51.100.7", "kind": "vm", "lab_n": 1}}}


def done(rc, out=""):
    return subprocess.CompletedProcess([], rc, stdout=out)


class TargetTest(unittest.TestCase):
    def setUp(self):
        self.t = target.get_target(CONF, "vm1")

    @mock.patch("subprocess.run", return_value=done(0, "ok\n"))
    def test_ssh_returns_code_and_output(self, run):
        self.assertEqual(self.t.ssh("echo ok"), (0, "ok\n"))

    @mock.patch("subprocess.run", side_effect=subprocess.TimeoutExpired("ssh", 20))
    def test_ssh_timeout_is_255_not_an_error(self, run):
        self.assertEqual(self.t.ssh("sleep 99"), (255, ""))

    @mock.patch("subprocess.run", return_value=done(0))
    def test_ssh_command_has_key_and_batchmode(self, run):
        self.t.ssh("true")
        argv = run.call_args[0][0]
        self.assertIn("-i", argv)
        self.assertIn("/k/id_test", argv)
        self.assertIn("BatchMode=yes", argv)
        self.assertIn("root@198.51.100.7", argv)

    @mock.patch("subprocess.run", return_value=done(1, "no space"))
    def test_put_raises_on_failure(self, run):
        with tempfile.NamedTemporaryFile() as f:
            with self.assertRaises(RuntimeError):
                self.t.put(f.name, "/etc/x")

    def test_get_target_unknown_name_exits(self):
        with self.assertRaises(SystemExit) as e:
            target.get_target(CONF, "vm9")
        self.assertIn("vm1", str(e.exception))

    def test_load_config_missing_file_exits(self):
        p = os.path.join(tempfile.mkdtemp(), "nope.json")
        with self.assertRaises(SystemExit) as e:
            target.load_config(p)
        self.assertIn(p, str(e.exception))


if __name__ == "__main__":
    unittest.main()
