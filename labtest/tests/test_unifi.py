import os
import tempfile
import unittest
from unittest import mock

from labtest import unifi


def answer(code=200, data=None, meta=None):
    r = mock.Mock(status_code=code)
    r.json.return_value = {"data": data or [], "meta": meta or {"rc": "ok"}}
    return r


class ControllerTest(unittest.TestCase):
    def setUp(self):
        fd, self.acct = tempfile.mkstemp()
        os.write(fd, b"u\ns3cret-word\n")
        os.close(fd)
        self.conf = {"controller": "https://198.51.100.9:8443", "site": "default", "account_file": self.acct}
        p = mock.patch("requests.Session")
        self.session = p.start().return_value
        self.addCleanup(p.stop)
        self.session.cookies.get.return_value = "T"
        self.session.post.return_value = answer()
        self.session.get.return_value = answer()
        self.session.put.return_value = answer()

    def test_login_posts_the_account(self):
        unifi.Controller(self.conf).login()
        url = self.session.post.call_args[0][0]
        self.assertEqual(url, "https://198.51.100.9:8443/api/login")
        self.assertEqual(self.session.post.call_args[1]["json"], {"username": "u", "password": "s3cret-word"})

    def test_put_sends_the_csrf_token(self):
        unifi.Controller(self.conf).put("rest/wlanconf/1", {"x": 1})
        self.assertEqual(self.session.put.call_args[0][0], "https://198.51.100.9:8443/api/s/default/rest/wlanconf/1")
        self.assertEqual(self.session.put.call_args[1]["headers"]["X-CSRF-Token"], "T")

    def test_get_returns_the_data_list(self):
        self.session.get.return_value = answer(data=[{"_id": "a"}])
        self.assertEqual(unifi.Controller(self.conf).devices(), [{"_id": "a"}])
        self.assertTrue(self.session.get.call_args[0][0].endswith("/api/s/default/stat/device"))

    def test_error_text_never_holds_the_password(self):
        self.session.post.return_value = answer(400)
        with self.assertRaises(RuntimeError) as e:
            unifi.Controller(self.conf).login()
        self.assertIn("400", str(e.exception))
        self.assertNotIn("s3cret-word", str(e.exception))

    def test_force_push_flips_uapsd(self):
        self.session.get.return_value = answer(data=[{"_id": "w1", "uapsd_enabled": False}])
        unifi.Controller(self.conf).force_push("w1")
        self.assertTrue(self.session.put.call_args[0][0].endswith("rest/wlanconf/w1"))
        self.assertEqual(self.session.put.call_args[1]["json"], {"uapsd_enabled": True})

    def queue(self, *replies):
        """get, post and put answer from one list, in call order."""
        q = list(replies)
        for m in (self.session.get, self.session.post, self.session.put):
            m.side_effect = lambda *a, **k: q.pop(0)

    def test_400_is_refused_with_the_controllers_reason(self):
        self.queue(answer(400, meta={"rc": "error", "msg": "api.err.InvalidPayload"}))
        with self.assertRaises(unifi.Refused) as e:
            unifi.Controller(self.conf).put("rest/wlanconf/1", {"x": 1})
        self.assertIn("api.err.InvalidPayload", str(e.exception))
        self.assertIn("rest/wlanconf/1", str(e.exception))

    def test_400_on_login_is_not_refused_and_holds_no_password(self):
        self.queue(answer(400, meta={"rc": "error", "msg": "s3cret-word"}))
        with self.assertRaises(RuntimeError) as e:
            unifi.Controller(self.conf).login()
        self.assertNotIsInstance(e.exception, unifi.Refused)
        self.assertNotIn("s3cret-word", str(e.exception))

    def test_401_logs_in_again_once(self):
        self.queue(answer(401), answer(200), answer(200, data=[{"_id": "1"}]))  # call, login, call again
        self.assertEqual(unifi.Controller(self.conf).get("rest/wlanconf"), [{"_id": "1"}])
        self.assertEqual(self.session.post.call_count, 1)

    def test_second_401_raises(self):
        self.queue(answer(401), answer(200), answer(401))
        with self.assertRaises(RuntimeError):
            unifi.Controller(self.conf).get("rest/wlanconf")

    def test_settings_and_device(self):
        self.queue(answer(data=[{"key": "ntp"}]), answer(data=[{"ip": "h", "_id": "d1"}]),
                   answer(data=[{"ip": "x"}]))
        c = unifi.Controller(self.conf)
        self.assertEqual(c.settings(), [{"key": "ntp"}])
        self.assertEqual(c.device("h")["_id"], "d1")
        self.assertIsNone(c.device("h"))

    def test_locate(self):
        data = {"rest/wlanconf": [{"_id": "w0", "name": "X"}, {"_id": "w1", "name": "T"}],
                "stat/device": [{"_id": "d1", "ip": "h"}],
                "rest/setting": [{"_id": "s1", "key": "guest_access", "x": 1}]}
        self.session.get.side_effect = lambda url, **k: answer(data=data[url.split("/default/")[1]])
        c = unifi.Controller(self.conf)
        self.assertEqual(c.locate("WlanConf", "h", "T"), ("rest/wlanconf/w1", {"_id": "w1", "name": "T"}))
        self.assertEqual(c.locate("Device", "h", "T")[0], "rest/device/d1")
        self.assertEqual(c.locate("Setting.guest_access", "h", "T")[0], "rest/setting/guest_access/s1")
        self.assertIsNone(c.locate("Setting.ntp", "h", "T"))
        self.assertIsNone(c.locate("WlanConf", "h", "nope"))
        self.assertIsNone(c.locate("Device", "other", "T"))

    def test_missing_account_file_is_a_clear_error(self):
        self.conf["account_file"] = self.acct + ".gone"
        with self.assertRaises(RuntimeError) as e:
            unifi.Controller(self.conf).login()
        self.assertIn("account file", str(e.exception))


if __name__ == "__main__":
    unittest.main()
