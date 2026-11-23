#!/usr/bin/env python3
"""07-tty-capture.py <id> <servers> <question> — the same question as 04-ask.sh, but in the
interactive Claude Code UI, run in a pseudo-terminal of 120 x 50. Every byte Claude Code
writes is saved to .run/tty/<id>.bin; 07-render.mjs replays it in xterm.js and takes the
screenshot (captures/07-<id>.png), so the picture is what the terminal showed at the end.

Runs in /tmp/lab-langfuse-mcp-client (lib.sh CLIENT_DIR). Answers the folder-trust prompt (Down, Enter), waits until the screen has been quiet for 12 s
(at least 25 s in, at most 240 s), then sends Ctrl-C twice. The same minimal
environment as 04-ask.sh; HINT=1 adds schema-hint.md. Run 04-ask.sh first, so that
.run/ask/mcp-<servers>.json and the client directory exist."""
import fcntl, os, pty, re, select, struct, sys, termios, time
ANSI = re.compile(rb"\x1b\[[0-9;?<>]*[a-zA-Z~]|\x1b\][^\x07]*\x07")

LAB = os.path.dirname(os.path.abspath(__file__))
RUN = os.path.join(LAB, ".run")
qid, servers, question = sys.argv[1:4]
COLS, ROWS = 120, 50
CLIENT = "/tmp/lab-langfuse-mcp-client"   # lib.sh CLIENT_DIR, prepared by 04-ask.sh
import base64
# minimal environment, as in 04-ask.sh
env = {k: os.environ[k] for k in ("HOME", "PATH", "USER") if k in os.environ}
env.update(LANG=os.environ.get("LANG", "en_US.UTF-8"), TERM="xterm-256color", COLUMNS=str(COLS), LINES=str(ROWS),
           CLAUDE_CODE_DISABLE_AUTO_MEMORY="1", LANGFUSE_HOST=os.environ.get("LANGFUSE_HOST", "http://localhost:3000"),
           CLICKHOUSE_RO_PASSWORD=open(os.path.join(RUN, "ch-ro.env")).read().split("=", 1)[1].strip(),
           LANGFUSE_MCP_AUTH=base64.b64encode(f"{os.environ['LANGFUSE_PUBLIC_KEY']}:{os.environ['LANGFUSE_SECRET_KEY']}".encode()).decode())
args = ["claude", "--model", os.environ.get("CLAUDE_MODEL", "sonnet"), "--setting-sources", "project", "--permission-mode", "default",
        "--mcp-config", os.path.join(RUN, "ask", f"mcp-{servers}.json"), "--strict-mcp-config"]
if os.environ.get("HINT") == "1":
    args += ["--append-system-prompt-file", os.path.join(LAB, "schema-hint.md")]
args.append(question)

pid, fd = pty.fork()
if pid == 0:
    os.chdir(CLIENT)
    os.execvpe(args[0], args, env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
os.makedirs(os.path.join(RUN, "tty"), exist_ok=True)
out = bytearray(); start = last = time.time(); trusted = False
while True:
    r, _, _ = select.select([fd], [], [], 1.0)
    if r:
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        out += chunk; last = time.time()
        # the UI moves the cursor instead of printing spaces: match with escapes removed
        if not trusted and b"Itrustthisfolder" in ANSI.sub(b"", bytes(out[-6000:])).replace(b" ", b""):
            # the trust prompt starts on "No, exit": arrow down to "Yes, I trust this folder"
            time.sleep(0.5); os.write(fd, b"\x1b[B"); time.sleep(0.3); os.write(fd, b"\r"); trusted = True
    now = time.time()
    if (now - start > 25 and now - last > 12) or now - start > 240:
        break
open(os.path.join(RUN, "tty", f"{qid}.bin"), "wb").write(out)
try:
    os.write(fd, b"\x03"); time.sleep(0.5); os.write(fd, b"\x03")
except OSError:
    pass   # Claude Code already exited
time.sleep(1)
try:
    os.kill(pid, 9)
except ProcessLookupError:
    pass
print(f"✓ {qid}: {len(out)} bytes in {time.time() - start:.0f} s → .run/tty/{qid}.bin")
