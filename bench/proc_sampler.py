"""CPU use of a server's processes, every second until SIGTERM (B-1b): proc_sampler.py ROOT_PID out.csv
                                         proc_sampler.py --python ROOT_PID  prints the Python PIDs of the tree
                                         proc_sampler.py --others ROOT_PID DEV [ROOT_PID...]  prints pid=name of
                                           every process outside the trees that holds DEV (the GPU's device
                                           node) open; further roots: oif bench itself (its nvidia-smi telemetry).
                                           GPU status tools (nvidia-smi, rocm-smi, amd-smi) only read state and
                                           are not counted: someone may run `watch nvidia-smi` during a benchmark

Columns: t (s since start), pid, name (process title or command), cpu_pct (100 = one core busy), threads, rss_mib.
ROOT_PID is the container's first process (podman/docker inspect .State.Pid); its whole process tree is sampled, so
vLLM's API server(s) and EngineCore and Dynamo's frontend and worker show up as separate rows. Reads /proc only."""
import os, signal, sys, time

TCK = os.sysconf("SC_CLK_TCK")


def children():
    kids = {}
    for p in os.listdir("/proc"):
        if p.isdigit():
            try:
                ppid = int(open(f"/proc/{p}/stat").read().rsplit(")", 1)[1].split()[1])
            except Exception:
                continue
            kids.setdefault(ppid, []).append(int(p))
    return kids


def tree(root):
    kids, out, todo = children(), [], [root]
    while todo:
        p = todo.pop()
        out.append(p)
        todo += kids.get(p, [])
    return out


def name(pid):
    try:
        cmd = open(f"/proc/{pid}/cmdline", "rb").read().replace(b"\0", b" ").decode(errors="replace").strip()
    except Exception:
        cmd = ""
    return (cmd or open(f"/proc/{pid}/comm").read().strip())[:90].replace(",", " ")


def is_python(pid):
    try:
        return "python" in os.path.basename(os.readlink(f"/proc/{pid}/exe"))
    except Exception:
        return False


def stat(pid):
    f = open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()
    rss = int(open(f"/proc/{pid}/statm").read().split()[1]) * os.sysconf("SC_PAGE_SIZE") / 1048576
    return int(f[11]) + int(f[12]), int(f[17]), round(rss)  # utime + stime, threads, RSS MiB


if sys.argv[1] == "--python":
    print(" ".join(str(p) for p in tree(int(sys.argv[2])) if is_python(p)))
    sys.exit(0)
if sys.argv[1] == "--others":
    ours = {p for r in [sys.argv[2]] + sys.argv[4:] for p in tree(int(r))}
    dev, found = os.path.realpath(sys.argv[3]), []
    for p in os.listdir("/proc"):
        if not p.isdigit() or int(p) in ours:
            continue
        try:
            comm = open(f"/proc/{p}/comm").read().strip()
            if comm in ("nvidia-smi", "rocm-smi", "amd-smi"):
                continue
            if any(os.readlink(f"/proc/{p}/fd/{fd}") == dev for fd in os.listdir(f"/proc/{p}/fd")):
                found.append(f"{p}={comm.replace(' ', '_')}")
        except Exception:
            continue
    print(" ".join(found))
    sys.exit(0)

root, out = int(sys.argv[1]), sys.argv[2]
stop = False
signal.signal(signal.SIGTERM, lambda *_: globals().update(stop=True))
t0, last = time.time(), {}
with open(out, "w") as f:
    f.write("t,pid,name,cpu_pct,threads,rss_mib\n")
    while not stop:
        now = time.time()
        for pid in tree(root):
            try:
                ticks, threads, rss = stat(pid)
            except Exception:
                continue
            if pid in last:
                lt, lticks = last[pid]
                f.write(f"{now - t0:.1f},{pid},{name(pid)},{100 * (ticks - lticks) / TCK / (now - lt):.1f},{threads},{rss}\n")
            last[pid] = (now, ticks)
        f.flush()
        time.sleep(1)
