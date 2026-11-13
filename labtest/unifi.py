"""Small UniFi controller API client for the LAB controller. The password is read from the
account file and never printed, logged or put in an error text."""
import requests
import urllib3

from labtest import catalog

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)  # lab controller: self-signed cert


class Refused(RuntimeError):
    """HTTP 400: the controller would not take the call. Text = path + the reply's meta.msg only."""


class Controller:
    def __init__(self, conf):
        self.base, self.site, self.account_file = conf["controller"].rstrip("/"), conf["site"], conf["account_file"]
        self.s = requests.Session()
        self.s.verify = False

    def _check(self, r, path):
        if r.status_code == 400 and path != "/api/login":
            try:
                msg = r.json().get("meta", {}).get("msg", "")
            except (ValueError, AttributeError):
                msg = ""
            raise Refused(f"controller refused {path}: {msg}")
        if r.status_code != 200:
            raise RuntimeError(f"controller: HTTP {r.status_code} on {path}")  # never the body
        return r

    def _call(self, method, path, body=None):
        # a login that ran out after hours: one silent re-login, then the same call again
        for again in (True, False):
            kw = {} if method == "get" else {"json": body, "headers": self._headers()}
            r = getattr(self.s, method)(self._url(path), **kw)
            if r.status_code == 401 and again:
                self.login()
                continue
            return self._check(r, path).json()["data"]

    def _headers(self):
        token = self.s.cookies.get("csrf_token")
        return {"X-CSRF-Token": token} if token else {}

    def login(self):
        try:
            with open(self.account_file) as f:
                user, password = f.read().splitlines()[:2]
        except (OSError, ValueError):
            raise RuntimeError("controller: account file missing or not two lines (user, password)") from None
        self._check(self.s.post(f"{self.base}/api/login", json={"username": user, "password": password},
                                headers=self._headers()), "/api/login")

    def _url(self, path):
        return f"{self.base}/api/s/{self.site}/{path}"

    def get(self, path):
        return self._call("get", path)

    def put(self, path, body):
        return self._call("put", path, body)

    def post(self, path, body):
        return self._call("post", path, body)

    def delete(self, path):
        self._call("delete", path)

    def wlans(self):
        return self.get("rest/wlanconf")

    def devices(self):
        return self.get("stat/device")

    def settings(self):
        return self.get("rest/setting")

    def device(self, host):
        return next((d for d in self.devices() if d.get("ip") == host), None)

    def locate(self, obj, host, wlan_name):
        """(PUT path, current object) for a catalog object on this site, or None when there is none."""
        if obj == "WlanConf":
            o = next((w for w in self.wlans() if w.get("name") == wlan_name), None)
            return o and (f"rest/wlanconf/{o['_id']}", o)
        if obj == "Device":
            o = self.device(host)
            return o and (f"rest/device/{o['_id']}", o)
        sec = catalog.section(obj)
        o = sec and next((s for s in self.settings() if s.get("key") == sec), None)
        return o and (f"rest/setting/{sec}/{o['_id']}", o)

    def force_push(self, wlan_id):
        w = next(w for w in self.wlans() if w["_id"] == wlan_id)
        self.put(f"rest/wlanconf/{wlan_id}", {"uapsd_enabled": not w.get("uapsd_enabled", False)})
