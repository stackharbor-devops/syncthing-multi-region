"""Signed one-time tokens (enroll tokens, SSO grants, API tokens).

Format (ARCHITECTURE.md section 4):
    base64url(JSON claims) + "." + base64url(HMAC-SHA256(secret, JSON claims bytes))
No padding. Claims always carry typ, iat, exp, jti.

The caller burns the jti (db.use_jti) after a successful verify when the token is
single-use (enroll, sso). API tokens are looked up by jti in the tokens table instead.
Standard library only.
"""
import base64
import hashlib
import hmac
import json
import secrets
import string
import time

MAX_TOKEN_LEN = 8192
CLOCK_SKEW = 60  # seconds tolerated for iat in the future
_HEX = set(string.hexdigits)


class TokenError(Exception):
    """Token is malformed, forged, expired or of the wrong type."""


def _b64e(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _b64d(text):
    if not isinstance(text, str) or not text:
        raise TokenError("malformed token")
    if any(c not in string.ascii_letters + string.digits + "-_" for c in text):
        raise TokenError("malformed token")
    try:
        return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))
    except Exception:
        raise TokenError("malformed token")


def key_bytes(secret):
    """Normalise the HMAC key.

    config.json stores the secret as 64 hex chars. Callers may pass that str, its
    ASCII bytes, or bytes.fromhex() of it: all three give the same key, so the CLI
    (mint) and the server (verify) always agree.
    """
    if isinstance(secret, str):
        secret = secret.strip()
        if secret and len(secret) % 2 == 0 and all(c in _HEX for c in secret):
            return bytes.fromhex(secret)
        return secret.encode("utf-8")
    if isinstance(secret, (bytes, bytearray)):
        raw = bytes(secret)
        try:
            text = raw.decode("ascii").strip()
        except UnicodeDecodeError:
            return raw
        if len(text) >= 32 and len(text) % 2 == 0 and all(c in _HEX for c in text):
            return bytes.fromhex(text)
        return raw
    raise TypeError("secret must be bytes or str")


def _sign(secret, payload):
    return hmac.new(key_bytes(secret), payload, hashlib.sha256).digest()


def mint(secret, claims, ttl_seconds):
    """Return a signed token. Adds iat, exp and a random 128-bit jti.

    claims must contain "typ". Existing iat/exp/jti in claims are overwritten.
    """
    if not isinstance(claims, dict) or not claims.get("typ"):
        raise ValueError("claims must be a dict with a 'typ'")
    ttl = int(ttl_seconds)
    if ttl <= 0:
        raise ValueError("ttl_seconds must be > 0")
    if len(key_bytes(secret)) < 16:
        raise ValueError("secret too short")
    now = int(time.time())
    body = dict(claims)
    body["iat"] = now
    body["exp"] = now + ttl
    body["jti"] = secrets.token_hex(16)
    payload = json.dumps(body, separators=(",", ":"), sort_keys=True).encode("utf-8")
    return _b64e(payload) + "." + _b64e(_sign(secret, payload))


def verify(secret, token, typ):
    """Verify signature (constant time), typ and expiry. Returns the claims dict.

    Raises TokenError. Does NOT burn the jti: the caller does that with db.use_jti.
    """
    if not isinstance(token, str) or not token or len(token) > MAX_TOKEN_LEN:
        raise TokenError("malformed token")
    parts = token.strip().split(".")
    if len(parts) != 2:
        raise TokenError("malformed token")
    payload = _b64d(parts[0])
    sig = _b64d(parts[1])
    expected = _sign(secret, payload)
    if not hmac.compare_digest(sig, expected):
        raise TokenError("bad signature")
    try:
        claims = json.loads(payload.decode("utf-8"))
    except Exception:
        raise TokenError("malformed claims")
    if not isinstance(claims, dict):
        raise TokenError("malformed claims")
    if not typ or claims.get("typ") != typ:
        raise TokenError("wrong token type")
    exp, iat, jti = claims.get("exp"), claims.get("iat"), claims.get("jti")
    if not isinstance(exp, int) or isinstance(exp, bool):
        raise TokenError("missing exp")
    if not isinstance(iat, int) or isinstance(iat, bool):
        raise TokenError("missing iat")
    if not isinstance(jti, str) or not jti:
        raise TokenError("missing jti")
    now = int(time.time())
    if now >= exp:
        raise TokenError("token expired")
    if iat > now + CLOCK_SKEW:
        raise TokenError("token issued in the future")
    return claims
