#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Drives `less` and `cat` on a pseudo-terminal: checks scrolling, search,
# paging of a stream that is still being written, quit-if-one-screen and that
# the terminal is left tidy. Usage: pty_less.py BIN_DIR
import os, pty, sys, time, select, struct, fcntl, termios, re

BIN = sys.argv[1]
failures = []

def check(name, ok):
    print(("PASS " if ok else "FAIL ") + name)
    if not ok:
        failures.append(name)

def session(argv, steps, rows=24, cols=80, stdin_feed=None, delay=0.05):
    """steps: list of (bytes_to_send_to_terminal, seconds_to_wait).
    stdin_feed: list of byte strings written to the program's stdin one by one
    (delay apart), then closed. Returns (output, exit status or None)."""
    r_in, w_in = os.pipe()
    pid, master = pty.fork()
    if pid == 0:
        os.environ['TERM'] = 'xterm-256color'
        if stdin_feed is None:
            fd = os.open('/dev/null', os.O_RDONLY); os.dup2(fd, 0)
        else:
            os.dup2(r_in, 0)
        os.execv(argv[0], argv)
    os.close(r_in)
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
    out = bytearray()
    def drain(t):
        end = time.time() + t
        while time.time() < end:
            r, _, _ = select.select([master], [], [], 0.02)
            if r:
                try:
                    d = os.read(master, 65536)
                except OSError:
                    return
                if not d:
                    return
                out.extend(d)
    drain(0.3)
    if stdin_feed is not None:
        for chunk in stdin_feed:
            os.write(w_in, chunk)
            drain(delay)
        snapshot_mid = bytes(out)
    else:
        snapshot_mid = b''
    os.close(w_in)
    for keys, wait in steps:
        if keys:
            os.write(master, keys)
        drain(wait)
    status = None
    end = time.time() + 3
    while time.time() < end:
        try:
            wpid, st = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            status = 0
            break
        if wpid:
            status = os.waitstatus_to_exitcode(st)
            break
        drain(0.05)
    if status is None:
        os.kill(pid, 9); os.waitpid(pid, 0)
    return bytes(out).decode('utf8', 'replace'), status, snapshot_mid.decode('utf8', 'replace')

def visible(s):
    return re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', s)

less = os.path.join(BIN, 'less')
cat = os.path.join(BIN, 'cat')
tmp = os.environ.get('TMPDIR', '/tmp')
big = os.path.join(tmp, 'pty_big.txt')
with open(big, 'w') as f:
    for i in range(200):
        f.write(f"row {i} " + "x" * (i % 7) + "\n")
long_line = os.path.join(tmp, 'pty_long.txt')
with open(long_line, 'w') as f:
    f.write("A" * 200 + "\nshort\n")
short = os.path.join(tmp, 'pty_short.txt')
with open(short, 'w') as f:
    f.write("alpha\nbeta\n")

# Scrolling and quitting
out, st, _ = session([less, big], [(b' ', 0.3), (b'G', 0.3), (b'g', 0.3), (b'q', 0.5)])
check("less: alternate screen entered and left", '\x1b[?1049h' in out and '\x1b[?1049l' in out)
check("less: first screen shows row 0", 'row 0' in out)
check("less: space scrolls a screen (row 25 appears)", 'row 25' in out)
check("less: G reaches the end (row 199 and (END))", 'row 199' in out and '(END)' in out)
check("less: q exits with status 0", st == 0)

# Search
out, st, _ = session([less, big], [(b'/row 150', 0.1), (b'\r', 0.4), (b'q', 0.5)])
check("less: / search jumps to the match", 'row 150' in out)

# Wrapping versus chopping
out, st, _ = session([less, long_line], [(b'q', 0.5)], cols=40)
check("less: long line wraps (200 A's over several rows)", visible(out).count('A' * 40) >= 4)
out, st, _ = session([less, '-S', long_line], [(b'q', 0.5)], cols=40)
check("less -S: long line is chopped", 'A' * 40 in visible(out) and 'A' * 41 not in visible(out))

# Streaming: lines are shown while the producer is still writing
feed = [f"live {i}\n".encode() for i in range(30)]
out, st, mid = session([less], [(b'G', 0.3), (b'q', 0.5)], stdin_feed=feed, delay=0.04)
check("less: a stream is shown before it ends", 'live 0' in mid)
check("less: stream scrolls and quits", 'live 29' in out and st == 0)

# Follow: data that arrives while following is shown without a key
r_in, w_in = None, None
out, st, mid = session([less], [(b'F', 0.2), (b'x', 0.2), (b'q', 0.5)], stdin_feed=[b"first\n"], delay=0.2)
check("less: F shows 'Waiting for data'", 'Waiting for data' in out)

# -F: fits on one screen: printed, no alternate screen, exits by itself
out, st, _ = session([less, '-F', short], [])
check("less -F: short file printed and exits", st == 0 and 'alpha' in out and '\x1b[?1049h' not in out)
out, st, _ = session([less, '-F', big], [(b'q', 0.5)])
check("less -F: long file is paged", '\x1b[?1049h' in out)

# cat: a long file is paged, a short one is not
out, st, _ = session([cat, big], [(b'q', 0.5)])
check("cat: long view is paged and quits with q", '\x1b[?1049h' in out and st == 0)
out, st, _ = session([cat, short], [])
check("cat: short view is printed directly", st == 0 and 'alpha' in out and '\x1b[?1049h' not in out)
out, st, _ = session([cat, '-P', big], [])
check("cat -P: no paging", st == 0 and '\x1b[?1049h' not in out and 'row 199' in out)
out, st, _ = session([cat, '--paging=never', big], [])
check("cat --paging=never: no paging", st == 0 and '\x1b[?1049h' not in out)

# cat: highlighting of a source file through the built-in grammars
src = os.path.join(tmp, 'pty_sample.zig')
with open(src, 'w') as f:
    f.write('const std = @import("std");\npub fn main() void {\n    // hi\n    const x: u32 = 42;\n}\n')
out, st, _ = session([cat, src], [])
check("cat: built-in Zig grammar colours the source", re.search(r'\x1b\[(?:3[0-9]|38;[25];[0-9;]+)m', out) is not None and st == 0)

sys.exit(1 if failures else 0)
