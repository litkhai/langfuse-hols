#!/usr/bin/env python3
"""16-sso-login.py — sign in to Langfuse through Keycloak the way a browser does, no browser.

    python3 16-sso-login.py --username bob@sso.test --password-file <file> [--idp-hint corp-saml]

Steps: NextAuth CSRF token → POST /api/auth/signin/keycloak (json=true) → follow the
authorization URL to Keycloak's login form → post the credentials → for a brokered SAML IdP,
post the SAMLResponse form Keycloak hands back → Langfuse's /api/auth/callback/keycloak sets
the session cookie → GET /api/auth/session.

`--idp-hint` is passed as a query parameter of the sign-in request; NextAuth forwards it to the
authorization URL, where Keycloak's `kc_idp_hint` skips its own login page and goes straight to
that identity provider.

Keycloak's frontend URL is http://keycloak:8088 (see _base/docker-compose.sso.yml), so the host
name `keycloak` is pinned to 127.0.0.1 in this process only.

Prints one JSON object: {"session": <session JSON or null>, "final_url": ..., "error": ...}.
Standard library only.
"""
import argparse
import html
import http.cookiejar
import json
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser

_real_getaddrinfo = socket.getaddrinfo


def _getaddrinfo(host, *args, **kwargs):
    return _real_getaddrinfo("127.0.0.1" if host == "keycloak" else host, *args, **kwargs)


socket.getaddrinfo = _getaddrinfo


class Forms(HTMLParser):
    """Collects every <form> with its action, id and named <input> values."""

    def __init__(self):
        super().__init__()
        self.forms, self._cur, self.title, self._in_title = [], None, "", False

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "form":
            self._cur = {"id": a.get("id", ""), "action": html.unescape(a.get("action") or ""), "inputs": {}}
            self.forms.append(self._cur)
        elif tag == "input" and self._cur is not None and a.get("name"):
            self._cur["inputs"][a["name"]] = a.get("value") or ""
        elif tag == "title":
            self._in_title = True

    def handle_endtag(self, tag):
        if tag == "form":
            self._cur = None
        elif tag == "title":
            self._in_title = False

    def handle_data(self, data):
        if self._in_title:
            self.title += data.strip()


def parse(body):
    p = Forms()
    p.feed(body)
    return p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="http://localhost:3000")
    ap.add_argument("--provider", default="keycloak")
    ap.add_argument("--idp-hint", default="")
    ap.add_argument("--username", required=True)
    ap.add_argument("--password-file", required=True)
    args = ap.parse_args()
    password = open(args.password_file).read().strip()

    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

    def fetch(url, data=None):
        body = urllib.parse.urlencode(data).encode() if data is not None else None
        try:
            r = opener.open(urllib.request.Request(url, data=body), timeout=60)
        except urllib.error.HTTPError as e:
            r = e
        return r.geturl(), r.read().decode("utf-8", "replace")

    def out(error=None, final_url=None):
        _, s = fetch(f"{args.host}/api/auth/session")
        try:
            session = json.loads(s) or None
        except ValueError:
            session = None
        print(json.dumps({"session": session, "final_url": final_url, "error": error}))
        return 0

    _, csrf = fetch(f"{args.host}/api/auth/csrf")
    token = json.loads(csrf)["csrfToken"]
    q = f"?{urllib.parse.urlencode({'kc_idp_hint': args.idp_hint})}" if args.idp_hint else ""
    _, r = fetch(f"{args.host}/api/auth/signin/{args.provider}{q}",
                 {"csrfToken": token, "callbackUrl": f"{args.host}/", "json": "true"})
    auth_url = json.loads(r)["url"]

    url, body = fetch(auth_url)
    page = parse(body)
    login = next((f for f in page.forms if f["id"] == "kc-form-login"), None)
    if login is None:
        return out(f"no Keycloak login form (page title: {page.title!r})", url)
    url, body = fetch(urllib.parse.urljoin(url, login["action"]),
                      {"username": args.username, "password": password, "credentialId": ""})

    # Up to a few auto-submit forms (SAML response, broker hand-offs) before Langfuse is reached.
    for _ in range(4):
        page = parse(body)
        if any(f["id"] == "kc-form-login" for f in page.forms):
            return out("Keycloak rejected the credentials (login form shown again)", url)
        saml = next((f for f in page.forms if "SAMLResponse" in f["inputs"]), None)
        if saml is None:
            break
        url, body = fetch(urllib.parse.urljoin(url, saml["action"]), saml["inputs"])

    error = None
    if not url.startswith(args.host):
        error = f"stopped at a Keycloak page (title: {page.title!r})"
    else:
        err = urllib.parse.parse_qs(urllib.parse.urlparse(url).query).get("error")
        if err:
            error = err[0]
    return out(error, url)


if __name__ == "__main__":
    sys.exit(main())
