#!/usr/bin/env python3
"""
Standalone latency/throughput microbenchmark for the etcd / mongodb /
zookeeper clusters that Janus uses as backends. Bypasses Janus
entirely — just hammers the leader directly with concurrent Put/Set
operations and measures aggregate tput + per-op latency.

Run from a Janus client host (e.g. server0) so the network path
matches what Janus's leader sees. Each "concurrent worker" is a
Python thread blocked on a sync RPC; the gRPC / wire protocol does
the rest. With N threads we get ~N in-flight ops.

Output (one CSV line per run, plus human-readable summary on stderr):
  backend,conc,duration_s,n_ops,tput_rps,p50_ms,p90_ms,p99_ms

Linearizable write semantics (matching what Janus uses):
  - mongodb: writeConcern=majority + j=true + linearizable read concern
  - etcd:    default (linearizable Put)
  - zookeeper: sync set (sync API, equivalent to Janus's zoo_set fix)

Usage examples:
  bench_backends.py etcd      --host 50.18.6.110 --conc 100 --duration 30
  bench_backends.py mongodb   --host 50.18.6.110 --conc 100 --duration 30
  bench_backends.py zookeeper --host 50.18.6.110 --conc 100 --duration 30
"""

import argparse, csv, statistics, sys, threading, time, uuid


def run_etcd(host, conc, duration_s, value_size):
    import etcd3
    val = b"v" * value_size
    cli = etcd3.client(host=host, port=2379, timeout=10)
    return _drive(
        f"etcd@{host}", conc, duration_s,
        lambda i, n: cli.put(f"/bench/{i}/{n}", val),
        cleanup=lambda: None,
    )


def run_mongodb(host, conc, duration_s, value_size):
    from pymongo import MongoClient, WriteConcern
    from pymongo.read_concern import ReadConcern
    val = "v" * value_size
    # Mirror Janus mongodb_kv_table_handler.h: directConnection, w=majority,
    # j=true, readConcern=linearizable. maxPoolSize sized to >= conc so the
    # connection pool isn't the bottleneck (default 100 caps tput at
    # ~conn_count / latency, which clamped earlier runs to 350 r/s).
    pool_size = max(conc, 100)
    uri = (f"mongodb://{host}:27017/?directConnection=true"
           f"&w=majority&journal=true&readConcernLevel=linearizable"
           f"&serverSelectionTimeoutMS=10000"
           f"&maxPoolSize={pool_size}&minPoolSize={min(conc, 50)}")
    cli = MongoClient(uri)
    db = cli["bench"].with_options(
        write_concern=WriteConcern(w="majority", j=True),
        read_concern=ReadConcern("linearizable"))
    coll = db["kv"]
    bench_id = uuid.uuid4().hex[:8]
    return _drive(
        f"mongodb@{host}", conc, duration_s,
        lambda i, n: coll.update_one(
            {"_id": f"{bench_id}-{i}-{n}"},
            {"$set": {"v": val}}, upsert=True),
        cleanup=lambda: cli.close(),
    )


def run_zookeeper(host, conc, duration_s, value_size):
    from kazoo.client import KazooClient
    val = (b"v" * value_size)
    # Each thread gets its own client (kazoo has internal locking; one
    # client + N threads can serialize on the connection mgmt thread).
    bench_root = f"/bench-{uuid.uuid4().hex[:8]}"
    bootstrap = KazooClient(hosts=f"{host}:2181", timeout=10.0)
    bootstrap.start(timeout=10)
    bootstrap.ensure_path(bench_root)
    bootstrap.stop(); bootstrap.close()

    clients = []
    def make_op(i, n):
        # Lazy per-thread client init.
        if i >= len(clients):
            while len(clients) <= i:
                clients.append(None)
        if clients[i] is None:
            c = KazooClient(hosts=f"{host}:2181", timeout=10.0)
            c.start(timeout=10)
            clients[i] = c
        path = f"{bench_root}/k{i}-{n}"
        clients[i].create(path, val, makepath=False)

    def cleanup():
        for c in clients:
            if c is not None:
                try: c.stop(); c.close()
                except: pass

    return _drive(f"zookeeper@{host}", conc, duration_s, make_op, cleanup=cleanup)


def _drive(label, conc, duration_s, op, cleanup=None):
    """Run `conc` worker threads for `duration_s`, each looping `op(i, n)`.
    Returns a dict with aggregate stats."""
    counts = [0] * conc
    latencies = [[] for _ in range(conc)]
    errors = [0] * conc
    stop_at = time.time() + duration_s

    def worker(i):
        n = 0
        while time.time() < stop_at:
            t0 = time.time()
            try:
                op(i, n)
            except Exception as e:
                errors[i] += 1
            else:
                latencies[i].append((time.time() - t0) * 1000.0)
                counts[i] += 1
            n += 1

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(conc)]
    t_start = time.time()
    for t in threads: t.start()
    for t in threads: t.join()
    elapsed = time.time() - t_start

    if cleanup is not None:
        try: cleanup()
        except: pass

    flat = sorted(l for ls in latencies for l in ls)
    n_ops = len(flat)
    n_err = sum(errors)
    if not flat:
        sys.stderr.write(f"[{label}] no successful ops, errors={n_err}\n")
        return None

    p = lambda q: flat[min(int(q * len(flat)), len(flat) - 1)]
    stats = dict(
        backend=label.split("@")[0], conc=conc, duration_s=duration_s,
        n_ops=n_ops, n_err=n_err, tput_rps=n_ops / elapsed,
        p50_ms=p(0.50), p90_ms=p(0.90), p99_ms=p(0.99),
        avg_ms=statistics.mean(flat),
    )
    sys.stderr.write(
        f"[{label}] conc={conc} ops={n_ops} err={n_err} "
        f"tput={stats['tput_rps']:.1f} r/s "
        f"p50={stats['p50_ms']:.1f} p90={stats['p90_ms']:.1f} "
        f"p99={stats['p99_ms']:.1f} avg={stats['avg_ms']:.1f} ms\n")
    return stats


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("backend", choices=["etcd", "mongodb", "zookeeper"])
    ap.add_argument("--host", default="50.18.6.110",
                    help="leader host (server0)")
    ap.add_argument("--conc", type=int, required=True)
    ap.add_argument("--duration", type=int, default=30)
    ap.add_argument("--value-size", type=int, default=8)
    args = ap.parse_args()

    runner = {"etcd": run_etcd, "mongodb": run_mongodb,
              "zookeeper": run_zookeeper}[args.backend]
    stats = runner(args.host, args.conc, args.duration, args.value_size)
    if stats is None:
        sys.exit(1)

    # CSV line on stdout (for downstream piping).
    print(",".join(str(stats[k]) for k in
        ["backend", "conc", "duration_s", "n_ops", "tput_rps",
         "p50_ms", "p90_ms", "p99_ms"]))


if __name__ == "__main__":
    main()
