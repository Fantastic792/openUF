import os
import subprocess
import tempfile
import unittest

from labtest import results


class ResultsTest(unittest.TestCase):
    def setUp(self):
        self.conf = {"results_dir": tempfile.mkdtemp()}

    def test_save_adds_commit_and_date_and_last_reads_it(self):
        p = results.save(self.conf, "timer-proof", {"pass": True})
        self.assertTrue(os.path.exists(p))
        d = results.last(self.conf, "timer-proof")
        self.assertIs(d["pass"], True)
        self.assertTrue(d["commit"])
        self.assertTrue(d["date"])

    def test_last_is_none_when_no_file(self):
        self.assertIsNone(results.last(self.conf, "nothing"))

    def test_commit_marks_a_dirty_tree(self):
        repo = tempfile.mkdtemp()
        git = ["git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.com"]
        subprocess.run(git + ["init", "-q"], check=True)
        subprocess.run(git + ["commit", "-q", "--allow-empty", "-m", "x"], check=True)
        self.assertNotIn("+dirty", results.commit(repo))
        open(os.path.join(repo, "new"), "w").close()
        self.assertTrue(results.commit(repo).endswith("+dirty"))


if __name__ == "__main__":
    unittest.main()
