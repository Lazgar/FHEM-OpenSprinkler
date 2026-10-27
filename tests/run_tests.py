#!/usr/bin/env python3
"""Integration test: mock OpenSprinkler + throw-away FHEM instance (own ports/directory) with the module from this repository.
Usage: python3 tests/run_tests.py [--fhem /opt/fhem]   (needs FHEM with its Perl dependencies; production FHEM is only read)
Ports: telnet 17073, mock 18090 (api) / 18091 (control)."""
import json, os, shutil, socket, subprocess, sys, time, urllib.parse, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
FHEM_SRC = sys.argv[sys.argv.index("--fhem") + 1] if "--fhem" in sys.argv else "/opt/fhem"
W = "/tmp/os-test"
TELNET, API, CTL = 17073, 18090, 18091
results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(("PASS " if ok else "FAIL ") + name + (("  (" + str(detail) + ")") if detail and not ok else ""), flush=True)


def ctl(path, **q):
    return json.loads(urllib.request.urlopen("http://127.0.0.1:%d/%s?%s" % (CTL, path, urllib.parse.urlencode(q)), timeout=5).read())


def fhem(cmd):
    s = socket.create_connection(("127.0.0.1", TELNET), timeout=10)
    s.sendall((cmd + "\n").encode())
    out, start = b"", time.time()
    s.settimeout(0.7)
    while time.time() - start < 15:
        try:
            d = s.recv(65536)
            if not d:
                break
            out += d
            start = max(start, time.time() - 14)
        except socket.timeout:
            if out:
                break
        except Exception:
            break
    try:
        s.sendall(b"quit\n")
    except Exception:
        pass
    s.close()
    return out.decode("utf-8", "replace").replace("\xff\xfb\x01", "").strip()


def reading(dev, r):
    try:
        return json.loads(fhem("jsonlist2 %s" % dev))["Results"][0]["Readings"][r]["Value"]
    except Exception:
        return None


def wait(cond, timeout=15, step=0.4):
    t = time.time()
    while time.time() - t < timeout:
        try:
            if cond():
                return True
        except Exception:
            pass
        time.sleep(step)
    return False


def setup():
    shutil.rmtree(W, ignore_errors=True)
    os.makedirs(W + "/fhem/log")
    shutil.copy(FHEM_SRC + "/fhem.pl", W + "/fhem/fhem.pl")
    subprocess.run(["cp", "-rs", FHEM_SRC + "/FHEM", W + "/fhem/FHEM"], check=True)
    for n in ("lib", "www", "contrib"):
        if os.path.exists(FHEM_SRC + "/" + n):
            os.symlink(FHEM_SRC + "/" + n, W + "/fhem/" + n)
    shutil.rmtree(W + "/fhem/FHEM/FhemUtils", ignore_errors=True)       # own, empty key store (never the production one)
    os.makedirs(W + "/fhem/FHEM/FhemUtils")
    p = W + "/fhem/FHEM/73_OpenSprinkler.pm"
    if os.path.lexists(p):
        os.remove(p)
    shutil.copy(REPO + "/FHEM/73_OpenSprinkler.pm", p)
    open(W + "/fhem/test.cfg", "w").write("""attr global modpath %s/fhem
attr global logfile %s/fhem/log/fhem.log
attr global verbose 3
attr global statefile %s/fhem/fhem.save
define telnetPort telnet %d
define os OpenSprinkler 127.0.0.1:%d
""" % (W, W, W, TELNET, API))


def drop_privileges():
    if os.geteuid() != 0:
        return None
    import pwd
    try:
        u = pwd.getpwnam("fhem")
    except KeyError:
        return None
    subprocess.run(["chown", "-R", "%d:%d" % (u.pw_uid, u.pw_gid), W], check=True)

    def fn():
        os.setgid(u.pw_gid)
        os.setuid(u.pw_uid)
    return fn


def ports_free():
    for port in (TELNET, API, CTL):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=1).close()
            return "port %d is already in use (stale test instance?)" % port
        except OSError:
            pass
    return None


def main():
    busy = ports_free()
    if busy:
        raise SystemExit(busy)
    setup()
    pre = drop_privileges()
    mock = subprocess.Popen([sys.executable, HERE + "/mock_opensprinkler.py", str(API), str(CTL)], stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, preexec_fn=pre)
    time.sleep(1.5)
    fh = subprocess.Popen(["perl", "fhem.pl", "test.cfg"], cwd=W + "/fhem", stdout=subprocess.PIPE, stderr=subprocess.STDOUT, preexec_fn=pre)
    try:
        if not wait(lambda: "os" in fhem("list os"), 25):
            print(fh.stdout.read(2000).decode() if fh.poll() is not None else "FHEM did not start")
            raise SystemExit(1)

        # --- without password
        check("no password: state missing_password", wait(lambda: reading("os", "state") == "missing_password", 8), reading("os", "state"))
        sl = fhem("set os ?")
        check("no password: only 'password' offered, FHEM-conform text", sl.startswith("Unknown argument ?, choose one of") and "station_0_start" not in sl, sl)
        check("get without argument is answered", "needs at least one argument" in fhem("get os"), fhem("get os"))

        # --- password and polling
        fhem("set os password test")
        check("password set: connected", wait(lambda: reading("os", "state") == "connected", 15), reading("os", "state"))
        check("readings: name, water level, current", reading("os", "station_0_name") == "Zone 0" and reading("os", "water_level_percent") == "100" and reading("os", "current_mA") == "120")
        check("total_stations 8, no extension", reading("os", "total_stations") == "8" and reading("os", "extension_boards") == "0")
        sl = fhem("set os ?")
        check("set list contains stations, rainDelay, system_enabled", "station_7_start" in sl and "rainDelay" in sl and "system_enabled:on,off" in sl, sl)

        # --- validation
        check("start: text rejected", "whole number" in fhem("set os station_1_start abc"))
        check("start: zero rejected", "whole number" in fhem("set os station_1_start 0"))
        check("start: too long rejected", "whole number" in fhem("set os station_1_start 70000"))
        check("start: injection rejected", "whole number" in fhem("set os station_1_start 60&pw=x"))
        check("start: unknown station rejected", "not available" in fhem("set os station_9_start 60"))
        check("rainDelay: text rejected", "whole number" in fhem("set os rainDelay abc"))
        check("system_enabled: bad value rejected", "Usage" in fhem("set os system_enabled maybe"))
        check("nothing was sent to the controller by rejected commands", ctl("state")["calls"] == [], ctl("state")["calls"])

        # --- commands
        fhem("set os station_1_start 120")
        check("start -> /cm sid=1 en=1 t=120", wait(lambda: any(c["path"] == "/cm" and c["q"].get("sid") == "1" and c["q"].get("t") == "120" and c["q"].get("en") == "1" for c in ctl("state")["calls"]), 8))
        check("duration reading only after success", wait(lambda: reading("os", "station_1_duration") == "120", 8), reading("os", "station_1_duration"))
        check("station_1_state on after poll", wait(lambda: reading("os", "station_1_state") == "on", 10), reading("os", "station_1_state"))
        check("last_command_result ok", reading("os", "last_command_result") == "ok", reading("os", "last_command_result"))
        fhem("set os station_1_stop")
        check("stop -> station off", wait(lambda: reading("os", "station_1_state") == "off", 10), reading("os", "station_1_state"))
        fhem("set os rainDelay 5")
        check("rainDelay -> /cv rd=5, reading on", wait(lambda: reading("os", "rain_delay_active") == "on", 10), reading("os", "rain_delay_active"))
        fhem("set os system_enabled off")
        check("system_enabled off", wait(lambda: reading("os", "system_enabled") == "off", 10), reading("os", "system_enabled"))
        fhem("set os system_enabled on")

        # --- controller rejects commands
        ctl("reject", on=1)
        fhem("set os station_2_start 60")
        check("rejected command: result reading error", wait(lambda: (reading("os", "last_command_result") or "").startswith("error"), 8), reading("os", "last_command_result"))
        check("rejected command: no duration reading", reading("os", "station_2_duration") is None, reading("os", "station_2_duration"))
        ctl("reject", on=0)

        # --- wrong password
        ctl("password", md5="ffffffffffffffffffffffffffffffff")
        fhem("get os status")
        check("wrong password detected", wait(lambda: reading("os", "state") == "wrong_password", 10), reading("os", "state"))
        ctl("password", md5="098f6bcd4621d373cade4e832627b4f6")
        fhem("get os status")
        check("back to connected after password is accepted again", wait(lambda: reading("os", "state") == "connected", 10), reading("os", "state"))

        # --- controller down
        ctl("down", on=1)
        fhem("get os status")
        check("controller unreachable: state error", wait(lambda: reading("os", "state") == "error", 10), reading("os", "state"))
        ctl("down", on=0)
        fhem("get os status")
        check("controller back: connected", wait(lambda: reading("os", "state") == "connected", 10))

        # --- attributes
        check("interval 0 rejected", "minimum 5" in fhem("attr os interval 0"), fhem("attr os interval 0"))
        check("interval text rejected", "minimum 5" in fhem("attr os interval abc"))
        check("interval 30 accepted", fhem("attr os interval 30") == "")
        fhem("attr os disable 1")
        check("disable: locked reading 1", wait(lambda: reading("os", "locked") == "1", 8), reading("os", "locked"))
        check("disable: polling continues (connected)", reading("os", "state") == "connected", reading("os", "state"))
        check("disable: rainDelay refused", "disabled" in fhem("set os rainDelay 1"))
        check("disable: station start refused", "disabled" in fhem("set os station_1_start 60"))
        fhem("attr os disable 0")
        check("enable again: locked reading 0", wait(lambda: reading("os", "locked") == "0", 8), reading("os", "locked"))
        fhem("get os status")
        check("enable again: connected", wait(lambda: reading("os", "state") == "connected", 10), reading("os", "state"))

        # --- extension board: firmware counts 8 stations per board (here 1 board -> 16 stations)
        ctl("boards", n=1)
        fhem("get os status")
        check("1 extension board -> total_stations 16", wait(lambda: reading("os", "total_stations") == "16", 10), reading("os", "total_stations"))
        sl = fhem("set os ?")
        check("1 extension board: station_15 offered, station_16 not", "station_15_start" in sl and "station_16_start" not in sl, sl[-120:])
        check("start on station 16 refused", "not available" in fhem("set os station_16_start 60"))
    finally:
        try:
            fhem("shutdown")                    # clean shutdown through FHEM itself
        except Exception:
            pass
        mock.terminate()
        try:
            fh.wait(10)
        except Exception:
            fh.terminate()
            try:
                fh.wait(5)
            except Exception:
                fh.kill()
                fh.wait()
        errs = open(W + "/fhem/log/fhem.log", errors="replace").read() if os.path.exists(W + "/fhem/log/fhem.log") else ""
        bad = [l for l in errs.splitlines() if "PERL WARNING" in l or "Undefined subroutine" in l or "Use of uninitialized" in l]
        check("no Perl warnings in the FHEM log", not bad, bad[:3])
    ok = sum(results)
    print("%d/%d checks passed" % (ok, len(results)))
    sys.exit(0 if ok == len(results) else 1)


if __name__ == "__main__":
    main()
