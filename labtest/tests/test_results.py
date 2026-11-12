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

    def _repo(self):
        repo = tempfile.mkdtemp()
        git = ["git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.com"]
        subprocess.run(git + ["init", "-q"], check=True)
        with open(os.path.join(repo, "tracked"), "w") as f:
            f.write("a")
        subprocess.run(git + ["add", "tracked"], check=True)
        subprocess.run(git + ["commit", "-q", "-m", "x"], check=True)
        return repo

    def test_commit_marks_a_modified_tracked_file_dirty(self):
        repo = self._repo()
        self.assertNotIn("+dirty", results.commit(repo))
        with open(os.path.join(repo, "tracked"), "w") as f:
            f.write("b")
        self.assertTrue(results.commit(repo).endswith("+dirty"))

    def test_commit_ignores_untracked_files(self):
        # the owner's untracked notes must not keep the "green on this commit" lock shut forever
        repo = self._repo()
        open(os.path.join(repo, "AI_CONTEXT.md"), "w").close()
        self.assertNotIn("+dirty", results.commit(repo))


if __name__ == "__main__":
    unittest.main()
