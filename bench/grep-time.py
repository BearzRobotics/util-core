# Times one command: python3 -I grep-time.py RUNS CMD ARG...
# Standard output goes to a pipe that is read and discarded (never /dev/null:
# GNU grep and ours exit at the first match there). Prints
# "wall_ms user_ms sys_ms rss_kb out_bytes status" for the fastest of RUNS
# runs (peak RSS is the largest seen). Used when `crap` cannot open perf
# events (kernel.perf_event_paranoid > 2), so there are no cycle counts.
import os, sys, time, subprocess, resource

runs = int(sys.argv[1])
cmd = sys.argv[2:]
best = None
rss = 0
for _ in range(runs):
    t0 = time.perf_counter()
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    n = 0
    while True:
        b = os.read(p.stdout.fileno(), 1 << 20)
        if not b:
            break
        n += len(b)
    _, st, ru = os.wait4(p.pid, 0)
    p.returncode = 0
    wall = (time.perf_counter() - t0) * 1000
    status = os.waitstatus_to_exitcode(st)
    rss = max(rss, ru.ru_maxrss)
    rec = (wall, ru.ru_utime * 1000, ru.ru_stime * 1000, n, status)
    if best is None or rec[0] < best[0]:
        best = rec
print("%.1f %.1f %.1f %d %d %d" % (best[0], best[1], best[2], rss, best[3], best[4]))
