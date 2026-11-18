#!/usr/bin/env python3
"""
ui.py — the browser side of a Langfuse release, without a browser: NextAuth sign-in and tRPC calls.

    ui.py login  <base> <jar>                      # sign in with the lab admin, save the cookies
    ui.py session <base> <jar>                     # GET /api/auth/session with the saved cookies
    ui.py trpc <base> <jar> <procedure> <json> [--query]

Cookies are host-scoped, not port-scoped, so a jar saved against one port-forward is sent to
another one on 127.0.0.1: that is how 06 presents a v3 session cookie to v4.
"""
import http.cookiejar
import json
import os
import sys
import urllib.parse
import urllib.request

USER = os.environ.get("LF_USER", "admin@example.com")
PASSWORD = os.environ.get("LF_PASSWORD", "sbs-lab-password")


def opener(jar_path, load=True):
    jar = http.cookiejar.LWPCookieJar(jar_path)
    if load and os.path.exists(jar_path):
        jar.load(ignore_discard=True, ignore_expires=True)
    return jar, urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))


def call(op, url, data=None, headers=None):
    req = urllib.request.Request(url, data=data, headers=headers or {})
    try:
        with op.open(req, timeout=60) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")


def login(base, jar_path):
    jar, op = opener(jar_path, load=False)
    _, body = call(op, f"{base}/api/auth/csrf")
    csrf = json.loads(body)["csrfToken"]
    form = urllib.parse.urlencode({"email": USER, "password": PASSWORD, "csrfToken": csrf,
                                   "callbackUrl": base, "json": "true"}).encode()
    code, _ = call(op, f"{base}/api/auth/callback/credentials", form,
                   {"Content-Type": "application/x-www-form-urlencoded"})
    jar.save(ignore_discard=True, ignore_expires=True)
    names = sorted(c.name for c in jar)
    print(f"login {code}, cookies: {', '.join(names)}")
    if not any("session-token" in n for n in names):
        sys.exit("no session cookie")


def session(base, jar_path):
    _, op = opener(jar_path)
    code, body = call(op, f"{base}/api/auth/session")
    data = json.loads(body or "{}")
    print(json.dumps({"http": code, "user": (data.get("user") or {}).get("email")}))


def trpc(base, jar_path, proc, payload, query=False):
    _, op = opener(jar_path)
    wrapped = json.dumps({"0": {"json": json.loads(payload)}})
    if query:
        code, body = call(op, f"{base}/api/trpc/{proc}?batch=1&input={urllib.parse.quote(wrapped)}")
    else:
        code, body = call(op, f"{base}/api/trpc/{proc}?batch=1", wrapped.encode(),
                          {"Content-Type": "application/json"})
    print(json.dumps({"http": code, "body": json.loads(body) if body.startswith(("[", "{")) else body[:300]}))


if __name__ == "__main__":
    cmd, base, jar = sys.argv[1:4]
    if cmd == "login":
        login(base, jar)
    elif cmd == "session":
        session(base, jar)
    elif cmd == "trpc":
        trpc(base, jar, sys.argv[4], sys.argv[5], "--query" in sys.argv)
