import http.client
import struct
import unittest

from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

from labtest.extra import fake

MAC = bytes.fromhex("020000000001")


class FakeTest(unittest.TestCase):
    def test_encode_round_trips(self):
        frame = fake.encode(b'{"_type": "noop"}', MAC)
        iv, n = frame[16:32], struct.unpack(">I", frame[36:40])[0]
        dec = Cipher(algorithms.AES(bytes.fromhex(fake.DEFAULT_KEY)), modes.CBC(iv)).decryptor()
        padded = dec.update(frame[40:40 + n]) + dec.finalize()
        un = padding.PKCS7(128).unpadder()
        self.assertEqual(un.update(padded) + un.finalize(), b'{"_type": "noop"}')
        self.assertEqual(fake.decode(frame), b'{"_type": "noop"}')

    def test_frame_header_fields(self):
        frame = fake.encode(b"x" * 20, MAC)
        self.assertEqual(frame[:4], b"TNBU")
        self.assertEqual(struct.unpack(">I", frame[4:8])[0], 1)
        self.assertEqual(frame[8:14], MAC)
        self.assertEqual(struct.unpack(">H", frame[14:16])[0], 1)  # encrypted, not compressed
        self.assertEqual(struct.unpack(">I", frame[32:36])[0], 1)
        self.assertEqual(struct.unpack(">I", frame[36:40])[0], len(frame) - 40)
        self.assertEqual((len(frame) - 40) % 16, 0)

    def test_server_answers_and_counts(self):
        s = fake.Server("127.0.0.1", 0)
        s.start()
        self.addCleanup(s.stop)
        s.next = lambda req: (200, b"hello " + req[:4])
        c = http.client.HTTPConnection("127.0.0.1", s.port, timeout=5)
        c.request("POST", "/inform", body=b"TNBU....")
        r = c.getresponse()
        self.assertEqual((r.status, r.read()), (200, b"hello TNBU"))
        self.assertEqual(s.informs, 1)


if __name__ == "__main__":
    unittest.main()
