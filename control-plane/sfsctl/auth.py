"""Request authentication and role checks for the control-plane API."""

import hmac
import importlib
import os
import time

from . import config as config_mod

ROLES = ("viewer", "operator", "admin")
_RANK = {"viewer": 1, "operator": 2, "admin": 3}

SESSION_COOKIE = "sfs_session"
SESSION_TTL_ABS = 8 * 3600
SESSION_TTL_IDLE = 30 * 60
CSRF_HEADER = "X-SFS-CSRF"
LOOPBACK = ("127.0.0.1", "::1", "::ffff:127.0.0.1")


class AuthError(Exception):
    def __init__(self, status, message):
        Exception.__init__(self, message)
        self.status = status
        self.message = message


def tokens():
    return importlib.import_module("sfsctl.tokens")


def has_role(principal, role):
    if not principal:
        return False
    return _RANK.get(principal.get("role"), 0) >= _RANK[role]


def parse_cookies(header):
    out = {}
    for part in (header or "").split(";"):
        name, sep, value = part.strip().partition("=")
        if sep and name:
            out[name] = value
    return out


_local_cache = {"path": None, "mtime": None, "value": None}


def read_local_token(path):
    """The local admin token file (re-read when it changes)."""
    try:
        st = os.stat(path)
    except OSError:
        return None
    if _local_cache["path"] != path or _local_cache["mtime"] != st.st_mtime:
        try:
            with open(path, "r") as fh:
                value = fh.read().strip()
        except OSError:
            return None
        _local_cache.update(path=path, mtime=st.st_mtime, value=value or None)
    return _local_cache["value"]


def authenticate(cfg, db, headers, client_ip):
    """Return a principal dict {sub, email, role, via} or None (anonymous).

    via = "local" (local admin token, loopback only), "token" (API token), "session".
    Raises AuthError(401) for a presented but invalid credential.
    """
    authz = headers.get("Authorization") or ""
    if authz:
        scheme, _, cred = authz.partition(" ")
        cred = cred.strip()
        if scheme.lower() != "bearer" or not cred:
            raise AuthError(401, "unsupported authorization scheme")
        local = read_local_token(cfg.get("localTokenPath") or "")
        if local and hmac.compare_digest(cred.encode(), local.encode()):
            if client_ip not in LOOPBACK:
                raise AuthError(401, "local token is only accepted from loopback")
            return {"sub": "local-admin", "email": "", "role": "admin", "via": "local"}
        if "." not in cred:
            raise AuthError(401, "invalid token")
        tk = tokens()
        try:
            claims = tk.verify(config_mod.secret_bytes(cfg), cred, "api")
        except tk.TokenError as exc:
            raise AuthError(401, "invalid token: %s" % exc)
        rec = db.get_api_token(claims.get("tid") or "")
        if rec is None:
            raise AuthError(401, "token revoked")
        if int(rec["exp"]) < time.time():
            raise AuthError(401, "token expired")
        return {"sub": "token:%s" % rec["id"], "email": "", "role": rec["role"],
                "via": "token", "name": rec.get("name") or ""}
    sid = parse_cookies(headers.get("Cookie")).get(SESSION_COOKIE)
    if sid:
        sess = db.get_session(sid)
        if sess is None:
            return None
        return {"sub": sess["sub"], "email": sess["email"], "role": sess["role"],
                "via": "session", "sid": sid}
    return None


def actor_name(principal):
    if not principal:
        return "anonymous"
    if principal.get("email"):
        return "%s <%s>" % (principal.get("sub"), principal["email"])
    return principal.get("sub") or "unknown"


def csrf_ok(principal, method, headers):
    """Cookie-authenticated state changes must carry X-SFS-CSRF: 1."""
    if method in ("GET", "HEAD", "OPTIONS"):
        return True
    if not principal or principal.get("via") != "session":
        return True
    return (headers.get(CSRF_HEADER) or "").strip() == "1"


def session_cookie(sid, max_age=SESSION_TTL_ABS):
    return "%s=%s; Path=/; Max-Age=%d; Secure; HttpOnly; SameSite=Strict" % (
        SESSION_COOKIE, sid, max_age)


def clear_cookie():
    return "%s=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Strict" % SESSION_COOKIE
