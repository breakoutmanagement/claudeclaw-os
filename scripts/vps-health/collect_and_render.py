#!/usr/bin/env python3
"""
VPS stack health collector + renderer.

Collects host + Docker + process metrics from one or more targets (local or via
`tailscale ssh root@<host>`) in a SINGLE round-trip per host, then renders a
self-contained HTML report (emoji-LED tiles, dark theme, no external assets).

Usage:
  collect_and_render.py --out report.html [--json data.json] \
      --target "label=local" --target "label=trading-desk-lon1"

If no --target is given, defaults to the Breakout stack:
  - ts-cc-os-vanilla (agents)   -> local
  - trading-desk-lon1           -> tailscale ssh

Design notes:
  * Pure stdlib (no jq / no pip deps). Cheap to run from cron.
  * One SSH invocation per host; sections delimited by @@MARKERS@@.
  * Read-only. Never starts/stops anything.
"""
import argparse, subprocess, sys, json, datetime, html, shlex

REMOTE_SCRIPT = r'''
echo "@@HOST@@"
nproc
cat /proc/loadavg
free -m | awk '/Mem/{print $3" "$2}'
df -P / | awk 'NR==2{print $3" "$2" "$5}'
uptime -p 2>/dev/null || echo "n/a"
echo "@@DOCKER_STATS@@"
docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}' 2>/dev/null
echo "@@DOCKER_PS@@"
docker ps -a --format '{{.Names}}|{{.Status}}' 2>/dev/null
echo "@@PROC@@"
ps -eo comm,pcpu,pmem --sort=-pmem 2>/dev/null | grep -viE 'docker|containerd|runc|^COMMAND' | head -8
echo "@@END@@"
'''

# friendly emoji per known process / service name
PROC_EMOJI = {
    "caddy": "🌐", "next-server": "📊", "node": "🟩", "uvicorn": "💱",
    "python": "🐍", "python3": "🐍", "postgres": "🗄️", "warp-svc": "☁️",
    "fail2ban-server": "🛡️", "tailscaled": "🔗", "sshd": "🔑",
    "systemd": "⚙️", "systemd-journal": "📓", "auditd": "📋", "grok": "🤖",
}

def run(host, script):
    if host == "local":
        cmd = ["bash", "-c", script]
    else:
        cmd = ["tailscale", "ssh", f"root@{host}", script]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
        return out.stdout
    except Exception as e:
        return f"@@ERROR@@\n{e}\n"

def parse_sections(raw):
    sec, cur = {}, None
    for line in raw.splitlines():
        if line.startswith("@@") and line.endswith("@@"):
            cur = line.strip("@"); sec[cur] = []
            continue
        if cur is not None:
            sec[cur].append(line)
    return sec

def collect(label, host):
    raw = run(host, REMOTE_SCRIPT)
    if "ERROR" in raw and "@@HOST@@" not in raw:
        return {"label": label, "host": host, "error": raw.strip(), "online": False}
    s = parse_sections(raw)
    h = [x for x in s.get("HOST", []) if x.strip()]
    data = {"label": label, "host": host, "online": True,
            "cores": None, "load": None, "mem": None, "disk": None, "uptime": "",
            "containers": [], "procs": []}
    try:
        data["cores"] = int(h[0])
        la = h[1].split()
        data["load"] = [float(la[0]), float(la[1]), float(la[2])]
        mu, mt = h[2].split(); data["mem"] = {"used": int(mu), "total": int(mt)}
        du, dt, dp = h[3].split(); data["disk"] = {"used": du, "total": dt, "pct": dp}
        data["uptime"] = h[4] if len(h) > 4 else ""
    except Exception:
        pass
    for ln in s.get("DOCKER_STATS", []):
        if "|" not in ln: continue
        n, cpu, mem, memp = (ln.split("|") + ["", "", "", ""])[:4]
        data["containers"].append({"name": n, "cpu": cpu, "mem": mem, "memp": memp, "status": "running"})
    running = {c["name"] for c in data["containers"]}
    for ln in s.get("DOCKER_PS", []):
        if "|" not in ln: continue
        n, st = (ln.split("|") + ["", ""])[:2]
        if n not in running:
            data["containers"].append({"name": n, "cpu": "-", "mem": "-", "memp": "",
                                       "status": "stopped", "status_text": st})
        else:
            for c in data["containers"]:
                if c["name"] == n: c["status_text"] = st
    for ln in s.get("PROC", []):
        p = ln.split()
        if len(p) >= 3:
            data["procs"].append({"comm": p[0], "cpu": p[1], "mem": p[2]})
    return data

def emo_load(load, cores):
    if not load or not cores: return "⚪"
    r = load[0] / cores
    return "🟢" if r < 0.7 else ("🟡" if r < 1.0 else "🔴")

def emo_pct(pct):
    try: v = float(str(pct).rstrip("%"))
    except: return "⚪"
    return "🟢" if v < 70 else ("🟡" if v < 85 else "🔴")

def emo_container(c):
    if c["status"] == "stopped": return "⚫"
    stx = c.get("status_text", "").lower()
    if "unhealthy" in stx or "restarting" in stx: return "🔴"
    if "starting" in stx: return "🟡"
    return "🟢"

def tile(inner, cls=""):
    return f'<div class="tile {cls}">{inner}</div>'

def render(hosts, generated):
    css = """
    *{box-sizing:border-box} body{margin:0;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;
    background:#0d1117;color:#e6edf3;padding:24px}
    h1{font-size:20px;margin:0 0 4px} .sub{color:#8b949e;font-size:13px;margin-bottom:20px}
    h2{font-size:15px;margin:26px 0 10px;color:#c9d1d9;border-bottom:1px solid #21262d;padding-bottom:6px}
    .host{background:#161b22;border:1px solid #21262d;border-radius:12px;padding:18px;margin-bottom:22px}
    .hdr{display:flex;align-items:baseline;gap:10px;flex-wrap:wrap}
    .hdr .name{font-size:17px;font-weight:600} .hdr .meta{color:#8b949e;font-size:12px}
    .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(190px,1fr));gap:10px;margin-top:12px}
    .tile{background:#0d1117;border:1px solid #21262d;border-radius:10px;padding:10px 12px;font-size:13px}
    .tile .t{font-weight:600;display:flex;justify-content:space-between;gap:8px}
    .tile .m{color:#8b949e;font-size:12px;margin-top:4px;display:flex;justify-content:space-between}
    .stopped{opacity:.5}
    .statbar{display:flex;gap:18px;flex-wrap:wrap;margin-top:10px;font-size:13px}
    .statbar .s{background:#0d1117;border:1px solid #21262d;border-radius:8px;padding:8px 12px}
    .off{color:#f85149}
    .foot{color:#6e7681;font-size:11px;margin-top:24px;text-align:center}
    """
    parts = [f"<h1>🖥️ VPS Stack Health</h1><div class='sub'>Generated {html.escape(generated)} · read-only snapshot</div>"]
    for d in hosts:
        if not d.get("online"):
            parts.append(f"<div class='host'><div class='hdr'><span class='name'>🔴 {html.escape(d['label'])}</span> "
                         f"<span class='meta off'>OFFLINE / unreachable</span></div>"
                         f"<div class='meta'>{html.escape(d.get('error','')[:300])}</div></div>")
            continue
        load = d.get("load"); cores = d.get("cores"); mem = d.get("mem"); disk = d.get("disk")
        memp = round(mem["used"]/mem["total"]*100) if mem and mem["total"] else 0
        statbar = (
            f"<span class='s'>{emo_load(load,cores)} load {load[0]:.2f} / {load[1]:.2f} / {load[2]:.2f} · {cores} vCPU</span>"
            f"<span class='s'>{emo_pct(memp)} 🧠 {mem['used']}/{mem['total']} MB ({memp}%)</span>"
            f"<span class='s'>{emo_pct(disk['pct']) if disk else '⚪'} 💾 {disk['used']}/{disk['total']} ({disk['pct']})</span>"
            f"<span class='s'>⏱️ {html.escape(d.get('uptime',''))}</span>"
        ) if load else "<span class='s off'>metrics unavailable</span>"
        run_c = [c for c in d["containers"] if c["status"] == "running"]
        stop_c = [c for c in d["containers"] if c["status"] == "stopped"]
        ctiles = ""
        for c in run_c:
            ctiles += tile(f"<div class='t'><span>{emo_container(c)} {html.escape(c['name'])}</span></div>"
                           f"<div class='m'><span>⚙️ {html.escape(c['cpu'])}</span><span>🧠 {html.escape(c['mem'].split('/')[0].strip())}</span></div>")
        for c in stop_c:
            ctiles += tile(f"<div class='t'><span>{emo_container(c)} {html.escape(c['name'])}</span></div>"
                           f"<div class='m'><span>{html.escape(c.get('status_text','stopped'))}</span></div>", "stopped")
        ptiles = ""
        for p in d["procs"]:
            e = PROC_EMOJI.get(p["comm"], "🔧")
            ptiles += tile(f"<div class='t'><span>{e} {html.escape(p['comm'])}</span></div>"
                           f"<div class='m'><span>⚙️ {html.escape(p['cpu'])}%</span><span>🧠 {html.escape(p['mem'])}%</span></div>")
        push_badge = ""
        if "pushed_age_min" in d:
            am = d["pushed_age_min"]
            fresh = "🟢" if am < 720 else ("🟡" if am < 2880 else "🔴")
            push_badge = f"<span class='meta'>{fresh} 📥 pushed {am} min ago</span>"
        block = (f"<div class='host'><div class='hdr'><span class='name'>🟢 {html.escape(d['label'])}</span>"
                 f"<span class='meta'>{html.escape(d['host'])}</span>{push_badge}</div>"
                 f"<div class='statbar'>{statbar}</div>")
        if ctiles:
            block += f"<h2>📦 Containers ({len(run_c)} up{', '+str(len(stop_c))+' stopped' if stop_c else ''})</h2><div class='grid'>{ctiles}</div>"
        if ptiles:
            block += f"<h2>🔧 Top host processes</h2><div class='grid'>{ptiles}</div>"
        block += "</div>"
        parts.append(block)
    parts.append("<div class='foot'>ClaudeClaw VPS health · scripts/vps-health/collect_and_render.py</div>")
    return f"<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>VPS Stack Health</title><style>{css}</style></head><body>{''.join(parts)}</body></html>"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=None)
    ap.add_argument("--json", default=None)
    ap.add_argument("--target", action="append", default=[],
                    help='label=host  (host "local" or a tailscale name)')
    ap.add_argument("--intake", default=None,
                    help="directory of pushed per-host JSON files to ingest (agentless push)")
    ap.add_argument("--emit-host", default=None,
                    help="collect THIS host locally and print one host-dict JSON to stdout, then exit")
    args = ap.parse_args()

    # agentless push: a prod box emits its own single-host JSON for Taildrop
    if args.emit_host:
        print(json.dumps(collect(args.emit_host, "local")))
        return
    if not args.out:
        ap.error("--out is required unless --emit-host is used")
    targets = args.target or [
        "ts-cc-os-vanilla (agents)=local",
        "trading-desk-lon1=trading-desk-lon1",
    ]
    hosts = []
    for t in targets:
        label, _, host = t.partition("=")
        hosts.append(collect(label.strip(), host.strip()))
    # ingest agentless-push JSON (one host-dict per file), freshest wins by label
    if args.intake:
        import glob, os
        seen = {h["label"] for h in hosts}
        for fp in sorted(glob.glob(os.path.join(args.intake, "*.json"))):
            try:
                hd = json.load(open(fp))
                if isinstance(hd, dict) and hd.get("label") and hd["label"] not in seen:
                    age_min = int((datetime.datetime.now().timestamp() - os.path.getmtime(fp)) / 60)
                    hd["pushed_age_min"] = age_min
                    hosts.append(hd); seen.add(hd["label"])
            except Exception:
                continue
    generated = datetime.datetime.now().strftime("%Y-%m-%d %H:%M %Z").strip()
    htmlout = render(hosts, generated)
    with open(args.out, "w") as f:
        f.write(htmlout)
    if args.json:
        with open(args.json, "w") as f:
            json.dump({"generated": generated, "hosts": hosts}, f, indent=2)
    print(f"wrote {args.out}" + (f" and {args.json}" if args.json else ""))

if __name__ == "__main__":
    main()
