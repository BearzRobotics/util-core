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

def session(argv, steps, rows=24, cols=80, stdin_feed=None, delay=0.05, tty_stdin=False):
    """steps: list of (bytes_to_send_to_terminal, seconds_to_wait).
    stdin_feed: list of byte strings written to the program's stdin one by one
    (delay apart), then closed. Returns (output, exit status or None)."""
    r_in, w_in = os.pipe()
    pid, master = pty.fork()
    if pid == 0:
        os.environ['TERM'] = 'xterm-256color'
        if tty_stdin:
            pass
        elif stdin_feed is None:
            fd = os.open('/dev/null', os.O_RDONLY); os.dup2(fd, 0)
        else:
            os.dup2(r_in, 0)
        os.execv(argv[0], argv)
    os.close(r_in)
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
    out = bytearray()
    last_output = [0.0]
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
                last_output[0] = time.time()
    def settle(quiet=0.3, limit=10.0):
        """Read until nothing has arrived for `quiet` seconds."""
        end = time.time() + limit
        while time.time() < end and time.time() - last_output[0] < quiet:
            drain(0.05)
    drain(0.3)
    # A key sent before the pager has taken the terminal is thrown away when
    # it does, so on a busy machine a fixed delay is not enough (MISC-039).
    # Wait for the program to show something and then be done. (A program
    # reading the terminal itself may have nothing to show first.)
    if not tty_stdin and any(keys for keys, _ in steps):
        end = time.time() + 10
        while not out and time.time() < end:
            drain(0.05)
        settle()
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
        if not tty_stdin:
            settle()
    status = None
    # No cost when the program ends as it should.
    end = time.time() + 15
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

def screen(s):
    """The rows of the last frame that was drawn, without the status row."""
    frame = s.split('\x1b[H')[-1].split('\x1b[?1049l')[0]
    return [visible(r).rstrip('\r ') for r in frame.split('\r\n')[:-1]]

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

# Search. The typed pattern shows on the status row, so only the text rows of
# the last frame tell whether the view moved (VIEW-028).
out, st, _ = session([less, big], [(b'/150 x', 0.2), (b'\r', 0.5), (b'q', 0.5)])
check("less: / search puts the match at the top", screen(out)[:2] == ['row 150 xxx', 'row 151 xxxx'])
out, st, _ = session([less, big], [(b'G', 0.3), (b'?w 42', 0.2), (b'\r', 0.5), (b'q', 0.5)])
check("less: ? searches backwards", screen(out)[:2] == ['row 42', 'row 43 x'])

# The whole of a long line is searched (VIEW-024).
long2 = os.path.join(tmp, 'pty_long2.txt')
with open(long2, 'w') as f:
    f.write(''.join('before %d\n' % i for i in range(50)) + 'a' * 5000 + 'NEEDLE\n' + ''.join('after %d\n' % i for i in range(50)))
out, st, _ = session([less, '-S', long2], [(b'/NEEDLE', 0.2), (b'\r', 0.5), (b'q', 0.5)])
check('less: search finds text past 4096 bytes of a line', screen(out)[1:2] == ['after 0'] and 'Pattern not found' not in out)

# A signal that ends the pager leaves the screen and the terminal modes as they
# were (VIEW-023). The outer shell asks stty afterwards.
for name, number in [('HUP', 1), ('INT', 2), ('QUIT', 3), ('TERM', 15)]:
    for program in (less, cat):
        inner = '(sleep 1; kill -%s $$) & exec "$0" "$1"' % name
        out, st, _ = session(['/bin/sh', '-c', 'trap "" INT QUIT; ( trap - INT QUIT; /bin/sh -c \'%s\' "$1" "$2" ); echo "status $?"; stty -a < /dev/tty' % inner,
                              'sh', program, big], [(b'', 1.5)])
        after = out.split('status ')[-1]
        words = after.split()
        check('%s: SIG%s restores the screen and the modes' % (os.path.basename(program), name),
              '\x1b[?1049l' in out and words[:1] == [str(128 + number)] and 'icanon' in words and 'echo' in words)

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

# Follow a file that is still being written, scrolling meanwhile
def following(argv, grow):
    """Follow `grow`, adding a line before each key is sent."""
    with open(grow, 'w') as f:
        f.write(''.join(f"old {i}\n" for i in range(60)))
    def add(line):
        return "echo %s >> '%s'" % (line, grow)
    script = ("(sleep 1; %s; sleep 2; %s) & exec %s" %
              (add('added-first'), add('added-later'), argv))
    # F; wait for the first line; scroll up while the second arrives; G; quit.
    return session(['/bin/sh', '-c', script],
                   [(b'F', 2.0), (b'k', 2.0), (b'G', 1.0), (b'q', 0.5)])

grow = os.path.join(tmp, 'pty_grow.log')
for label, argv in [('less FILE', "'%s' '%s'" % (less, grow)), ('less <FILE', "'%s' <'%s'" % (less, grow))]:
    out, st, _ = following(argv, grow)
    check('%s: F shows what is added to a file' % label, 'added-first' in out)
    check('%s: following goes on after scrolling' % label,
          'Following (G' in out and 'added-later' in out and st == 0)

# -F: fits on one screen: printed, no alternate screen, exits by itself
out, st, _ = session([less, '-F', short], [])
check("less -F: short file printed and exits", st == 0 and 'alpha' in out and '\x1b[?1049h' not in out)
out, st, _ = session([less, '-F', big], [(b'q', 0.5)])
check("less -F: long file is paged", '\x1b[?1049h' in out)

# -F shows a short file as the pager would: no control sequence of the file
# reaches the terminal without -R.
hostile = os.path.join(tmp, 'pty_esc.txt')
with open(hostile, 'wb') as f:
    f.write(b'hi\x1b]0;OWNED\x07\x1b[2J\rthere\r\nred \x1b[31mtext\x1b[0m\n\ttab')
out, st, _ = session([less, '-F', hostile], [])
check('less -F: control characters of a short file are shown, not sent',
      st == 0 and '\x1b' not in out and '\x07' not in out and 'hi^[]0;OWNED^G^[[2J^Mthere' in out
      and '^[[31mtext' in out and '        tab' in out)
out, st, _ = session([less, '-F', '-R', hostile], [])
check('less -F -R: colours pass', st == 0 and 'red \x1b[31mtext\x1b[0m' in out)
out, st, _ = session([less, '-F', '-N', short], [])
check('less -F -N: lines are numbered', st == 0 and '     2 ' in visible(out) and 'beta' in out)
out, st, _ = session([cat, '-p', '--color=never', hostile], [])
check('cat: a short file is written as it is', st == 0 and 'hi\x1b]0;OWNED\x07\x1b[2J' in out)

# C1 controls and bytes that are not UTF-8 are shown: a terminal would obey
# U+009B as it does ESC [.
c1 = os.path.join(tmp, 'pty_c1.txt')
with open(c1, 'wb') as f:
    f.write(b'a\xc2\x9b2Jb c\x9bd caf\xc3\xa9\n')
for flags in [[], ['-R'], ['-F'], ['-F', '-R']]:
    out, st, _ = session([less, *flags, c1], [] if '-F' in flags else [(b'q', 0.5)])
    check('less %s: C1 controls are shown, not sent' % ' '.join(flags),
          st == 0 and 'a<U+009B>2Jb c<9B>d caf\u00e9' in out and '\x9b' not in out)

# -R lets colours and links through, and nothing that moves, erases or asks.
csi = os.path.join(tmp, 'pty_csi.txt')
with open(csi, 'wb') as f:
    f.write(b'x\x1b[6ny\x1b[2;1Hz\x1b[3Jw \x1b[32mgreen\x1b[m\n')
for flags in [['-R'], ['-r'], ['-F', '-R']]:
    out, st, _ = session([less, *flags, csi], [] if '-F' in flags else [(b'q', 0.5)])
    check('less %s: only colour sequences pass' % ' '.join(flags),
          st == 0 and 'x^[[6ny^[[2;1Hz^[[3Jw \x1b[32mgreen' in out
          and not any(s in out for s in ('\x1b[6n', '\x1b[2;1H', '\x1b[3J')))

# A file name is shown, not sent: in the header of cat's view and in less's
# position line.
evil = os.path.join(tmp, 'n\x1b]0;PWN\x07\nforged')
with open(evil, 'w') as f:
    f.write('x\n')
out, st, _ = session([cat, '--decorations=always', '--paging=never', '--color=never', evil], [])
check('cat: the header shows control characters of a name', st == 0 and 'n^[]0;PWN^G^Jforged' in out and '\x1b]0;' not in out)
named = os.path.join(tmp, 'n\x1b]0;T\x07.t')
with open(named, 'w') as f:
    f.write(''.join('line %d\n' % i for i in range(100)))
# From its own directory: only a short name is put in that line.
out, st, _ = session(['/bin/sh', '-c', 'cd "$1" && exec "$2" "$3"', 'sh', tmp, os.path.abspath(less), os.path.basename(named)],
                     [(b'=', 0.5), (b'q', 0.5)])
check('less: = does not send control characters of a name', st == 0 and 'n^[]0;T^G.tline 1/' in out and '\x1b]0;' not in out)
os.remove(evil)
os.remove(named)

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

# cat reading the terminal is just cat: no pager takes the keys, nothing is
# decorated, and Ctrl-D ends the input.
for label, argv in [('cat', [cat]), ('cat -', [cat, '-']), ('cat /dev/tty', [cat, '/dev/tty'])]:
    out, st, _ = session(argv, [(b'hello\r', 0.3), (b'world\r', 0.3), (b'\x04', 0.5)], tty_stdin=True)
    check('%s: typed lines are echoed and copied' % label,
          st == 0 and out.replace('\r', '') == 'hello\nhello\nworld\nworld\n')

# Another program in the pipeline reads the terminal: cat leaves it alone.
prompt = os.path.join(tmp, 'pty_prompt.sh')
with open(prompt, 'w') as f:
    f.write('printf "Password: " > /dev/tty\nIFS= read -r pw < /dev/tty\necho "producer got [$pw]"\n')
# (A named theme: by default cat asks the terminal for its background colour,
# and what is typed while it does is lost. These two look at the pager.)
out, st, _ = session(['/bin/sh', '-c', 'sh "%s" | "%s" --theme=ansi' % (prompt, cat)], [(b'hunter2\r', 0.8)], tty_stdin=True)
check('cat: a prompt earlier in the pipeline gets the keyboard', st == 0 and 'producer got [hunter2]' in out)

# What is typed while a short output is produced stays for the next reader.
for label, command in [('cat', '"%s" --theme=ansi' % cat), ('less -F', '"%s" -F' % less)]:
    out, st, _ = session(['/bin/sh', '-c', '{ sleep 1; echo short; } | %s; IFS= read -r x; echo "next got [$x]"' % command],
                         [(b'typed ahead\r', 1.5)], tty_stdin=True)
    check('%s: input typed ahead is not consumed' % label, st == 0 and 'next got [typed ahead]' in out)

# A long stream is still paged.
feed = [("piped %d\n" % i).encode() for i in range(60)]
out, st, _ = session([cat], [(b'', 0.5), (b'q', 0.5)], stdin_feed=feed, delay=0.01)
check('cat: a long piped stream is paged and quits with q', '\x1b[?1049h' in out and '\x1b[?1049l' in out and st == 0)

# cat with itself as the pager, directly or through a script. Unfixed, each cat
# starts another without end, so these run only inside a systemd scope that caps
# the number of processes and the memory, and which is stopped afterwards.
import shutil, subprocess
cap = ['-p', 'TasksMax=50', '-p', 'MemoryMax=1G', '-p', 'MemorySwapMax=0']
can_cap = shutil.which('systemd-run') is not None and subprocess.run(
    ['systemd-run', '--user', '--scope', '-q', *cap, '/bin/true'], capture_output=True).returncode == 0
if can_cap:
    bindir = os.path.join(tmp, 'pty_bin')
    os.makedirs(bindir, exist_ok=True)
    if not os.path.lexists(os.path.join(bindir, 'cat')):
        os.symlink(os.path.abspath(cat), os.path.join(bindir, 'cat'))
    wrapper = os.path.join(bindir, 'wrapper')
    with open(wrapper, 'w') as f:
        f.write('#!/bin/sh\nexec cat\n')
    os.chmod(wrapper, 0o755)
    one = os.path.join(tmp, 'pty_one.txt')
    with open(one, 'w') as f:
        f.write('only-this-line\n')
    cases = [('PAGER=cat', {'PAGER': 'cat'}, ''),
             ('BAT_PAGER=cat', {'BAT_PAGER': 'cat'}, ''),
             ('PAGER=/path/to/cat', {'PAGER': os.path.join(bindir, 'cat')}, ''),
             ('--pager=cat --paging=always', {}, '--pager=cat --paging=always '),
             ('a pager with arguments that runs cat', {'PAGER': 'cat -u'}, ''),
             ('a pager script that runs cat', {'PAGER': wrapper}, '')]
    for n, (label, env, options) in enumerate(cases):
        unit = 'util-core-pager-test-%d-%d.scope' % (os.getpid(), n)
        assign = ' '.join('%s="%s"' % kv for kv in env.items())
        # The unit variables are needed by systemd-run only.
        script = 'unset BAT_PAGER PAGER; export PATH="%s:/usr/bin:/bin"; %s exec "%s/cat" %s"%s"' % (
            bindir, ('export %s;' % assign) if assign else '', bindir, options, one)
        try:
            out, st, _ = session(['/usr/bin/env', 'systemd-run', '--user', '--scope', '-q', '--unit=' + unit,
                                  *cap, '/bin/sh', '-c', script], [(b'', 1.0)])
        finally:
            subprocess.run(['systemctl', '--user', 'kill', '--signal=KILL', unit], capture_output=True)
        check('cat: %s shows the file once and ends' % label, st == 0 and out.count('only-this-line') == 1)
        if label.startswith('a pager'):
            check('cat: %s does not number it twice' % label, len(re.findall(r'1[^\n]*only-this-line', visible(out))) <= 1
                  and visible(out).count('pty_one.txt') == 1)
else:
    print('SKIP cat as its own pager (no systemd scope to cap processes)')

sys.exit(1 if failures else 0)
