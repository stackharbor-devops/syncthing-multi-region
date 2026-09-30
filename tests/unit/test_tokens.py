"""Unit tests for sfsctl.tokens. Run: PYTHONPATH=control-plane python3 -m unittest discover -s tests/unit"""
import base64
import json
import time
import unittest
from unittest import mock

from sfsctl import tokens

SECRET_HEX = "ab" * 32


class TokenTests(unittest.TestCase):
    def test_round_trip_and_claims(self):
        t = tokens.mint(bytes.fromhex(SECRET_HEX), {"typ": "sso", "sub": "u1"}, 60)
        c = tokens.verify(bytes.fromhex(SECRET_HEX), t, "sso")
        self.assertEqual(c["sub"], "u1")
        self.assertEqual(c["exp"] - c["iat"], 60)
        self.assertEqual(len(c["jti"]), 32)
        self.assertEqual(t.count("."), 1)
        self.assertNotIn("=", t)

    def test_jti_unique(self):
        a = tokens.verify(SECRET_HEX, tokens.mint(SECRET_HEX, {"typ": "x"}, 5), "x")["jti"]
        b = tokens.verify(SECRET_HEX, tokens.mint(SECRET_HEX, {"typ": "x"}, 5), "x")["jti"]
        self.assertNotEqual(a, b)

    def test_secret_forms_equivalent(self):
        t = tokens.mint(SECRET_HEX, {"typ": "sso"}, 60)
        tokens.verify(bytes.fromhex(SECRET_HEX), t, "sso")
        tokens.verify(SECRET_HEX.encode(), t, "sso")

    def test_wrong_secret(self):
        t = tokens.mint(SECRET_HEX, {"typ": "sso"}, 60)
        with self.assertRaises(tokens.TokenError):
            tokens.verify("cd" * 32, t, "sso")

    def test_tampered_payload(self):
        t = tokens.mint(SECRET_HEX, {"typ": "enroll", "ip": "10.0.0.5", "roles": ["volume"]}, 60)
        p, s = t.split(".")
        claims = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
        claims["roles"] = ["master", "volume"]
        forged = base64.urlsafe_b64encode(json.dumps(claims).encode()).rstrip(b"=").decode()
        with self.assertRaises(tokens.TokenError):
            tokens.verify(SECRET_HEX, forged + "." + s, "enroll")

    def test_tampered_signature(self):
        t = tokens.mint(SECRET_HEX, {"typ": "sso"}, 60)
        p, s = t.split(".")
        s2 = ("A" if s[0] != "A" else "B") + s[1:]
        with self.assertRaises(tokens.TokenError):
            tokens.verify(SECRET_HEX, p + "." + s2, "sso")

    def test_expired(self):
        t = tokens.mint(SECRET_HEX, {"typ": "sso"}, 60)
        with mock.patch("time.time", return_value=time.time() + 61):
            with self.assertRaises(tokens.TokenError) as cm:
                tokens.verify(SECRET_HEX, t, "sso")
        self.assertIn("expired", str(cm.exception))

    def test_typ_confusion(self):
        enroll = tokens.mint(SECRET_HEX, {"typ": "enroll"}, 60)
        with self.assertRaises(tokens.TokenError):
            tokens.verify(SECRET_HEX, enroll, "sso")
        sso = tokens.mint(SECRET_HEX, {"typ": "sso"}, 60)
        with self.assertRaises(tokens.TokenError):
            tokens.verify(SECRET_HEX, sso, "enroll")
        with self.assertRaises(tokens.TokenError):
            tokens.verify(SECRET_HEX, sso, "")

    def test_malformed(self):
        for bad in ["", "abc", "a.b.c", "!!.??", "a" * 9000, None, 5, "e30.e30"]:
            with self.assertRaises(tokens.TokenError):
                tokens.verify(SECRET_HEX, bad, "sso")

    def test_mint_rejects_bad_input(self):
        with self.assertRaises(ValueError):
            tokens.mint(SECRET_HEX, {"sub": "x"}, 60)
        with self.assertRaises(ValueError):
            tokens.mint(SECRET_HEX, {"typ": "sso"}, 0)
        with self.assertRaises(ValueError):
            tokens.mint(b"short", {"typ": "sso"}, 60)


if __name__ == "__main__":
    unittest.main()
