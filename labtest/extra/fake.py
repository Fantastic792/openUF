"""A fake UniFi controller: builds inform frames and answers informs with whatever a test sets."""
import os
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

DEFAULT_KEY = "ba86f2bbe107c7c57eb5f2690775c712"  # the public key of every un-adopted device (openuf/state.lua)


def encode(payload, mac, key_hex=DEFAULT_KEY):
    """TNBU frame, AES-128-CBC, not compressed (layout of tools/test_controller.py encode_packet)."""
    iv = os.urandom(16)
    p = padding.PKCS7(128).padder()
    enc = Cipher(algorithms.AES(bytes.fromhex(key_hex)), modes.CBC(iv)).encryptor()
    ct = enc.update(p.update(payload) + p.finalize()) + enc.finalize()
    return (b"TNBU" + struct.pack(">I", 1) + mac + struct.pack(">H", 1) + iv + struct.pack(">I", 1)
            + struct.pack(">I", len(ct)) + ct)


def decode(frame, key_hex=DEFAULT_KEY):
    """The payload of an encode() frame; raises on anything else."""
    if frame[:4] != b"TNBU":
        raise ValueError("not a frame")
    n = struct.unpack(">I", frame[36:40])[0]
    dec = Cipher(algorithms.AES(bytes.fromhex(key_hex)), modes.CBC(frame[16:32])).decryptor()
    un = padding.PKCS7(128).unpadder()
    return un.update(dec.update(frame[40:40 + n]) + dec.finalize()) + un.finalize()


class _Handler(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802 -- http.server's name
        srv = self.server.owner
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        with srv.lock:
            srv.informs += 1
        rep = srv.next(body) if srv.next else (404, b"")
        if rep == "close":
            self.close_connection = True
            return
        if rep[0] == "slow":
            time.sleep(rep[1])
            rep = rep[2] if len(rep) > 2 else (200, b"")
        if rep[0] == "cut":  # ("cut", declared length, body): fewer bytes than promised, then close
            status, length, data = 200, rep[1], rep[2]
            self.close_connection = True
        else:
            status, data = rep
            length = len(data)
        self.send_response(status)
        self.send_header("Content-Type", "application/x-binary")
        self.send_header("Content-Length", str(length))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


class Server:
    def __init__(self, host, port=18080):
        self.host, self.port, self.next, self.informs, self.lock = host, port, None, 0, threading.Lock()
        self._httpd = self._thread = None

    def start(self):
        self._httpd = ThreadingHTTPServer((self.host, self.port), _Handler)
        self._httpd.daemon_threads, self._httpd.owner = True, self
        self.port = self._httpd.server_address[1]
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)
        self._thread.start()

    def stop(self):
        if self._httpd:
            self._httpd.shutdown()
            self._httpd.server_close()
