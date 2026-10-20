#!/usr/bin/env python3
"""Minimal mock of the OpenSprinkler HTTP API (/ja, /cm, /cv) for testing the FHEM module without a controller.
Usage: mock_opensprinkler.py [api-port=18090] [control-port=18091]
Control (127.0.0.1:<control-port>): /state, /password?md5=<hash>, /boards?n=<ext>, /reject?on=1|0, /down?on=1|0
Only the Python standard library is used."""
import json, sys, threading, time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

API = int(sys.argv[1]) if len(sys.argv) > 1 else 18090
CTL = int(sys.argv[2]) if len(sys.argv) > 2 else 18091
S = {"md5": "098f6bcd4621d373cade4e832627b4f6",   # md5("test")
     "ext": 0, "reject": False, "down": False, "calls": [], "en": 1, "rd": 0, "sn": {}}
lock = threading.Lock()


def nstations():
    return 8 + 8 * S["ext"]


def ja():
    n = nstations()
    return {"settings": {"en": S["en"], "rd": 1 if S["rd"] else 0, "rdst": int(time.time()) + S["rd"] * 3600 if S["rd"] else 0,
                         "curr": 120, "lrun": [1, 0, 600, int(time.time())]},
            "options": {"fwv": 221, "hwv": 23, "hwt": 172, "ext": S["ext"], "wl": 100},
            "stations": {"snames": ["Zone %d" % i for i in range(n)]},
            "status": {"sn": [S["sn"].get(i, 0) for i in range(n)], "nstations": n}}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        with lock:
            if S["down"]:
                self.send_response(503)
                self.end_headers()
                return
            if q.get("pw") != S["md5"]:
                return self._send({"result": 2})
            if u.path == "/ja":
                return self._send(ja())
            if u.path in ("/cm", "/cv"):
                S["calls"].append({"path": u.path, "q": q})
                if S["reject"]:
                    return self._send({"result": 16})
                if u.path == "/cm":
                    sid = int(q.get("sid", -1))
                    if sid < 0 or sid >= nstations():
                        return self._send({"result": 16})
                    S["sn"][sid] = 1 if q.get("en") == "1" else 0
                else:
                    if "rd" in q:
                        S["rd"] = int(q["rd"])
                    if "en" in q:
                        S["en"] = int(q["en"])
                return self._send({"result": 1})
            self._send({"result": 32})


class C(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        out = {"ok": True}
        with lock:
            if u.path == "/password":
                S["md5"] = q["md5"]
            elif u.path == "/boards":
                S["ext"] = int(q["n"])
            elif u.path == "/reject":
                S["reject"] = q.get("on", "1") == "1"
            elif u.path == "/down":
                S["down"] = q.get("on", "1") == "1"
            elif u.path == "/state":
                out = {k: v for k, v in S.items() if k != "md5"}
        b = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)


if __name__ == "__main__":
    srv = HTTPServer(("127.0.0.1", API), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    print("mock ready on %d / %d" % (API, CTL), flush=True)
    HTTPServer(("127.0.0.1", CTL), C).serve_forever()
