# VPS deploy (Hostinger + Tailscale)

One-shot, mostly-unattended deploy of ClaudeClaw OS onto a fresh Debian/Ubuntu VPS.
The bot runs as a hardened `systemd` service, and the dashboard is reachable **only**
by devices on your Tailscale network — over real HTTPS, on top of the existing
`DASHBOARD_TOKEN` gate.

> ClaudeClaw isn't officially "cloud supported" (see the main README's *Cloud
> deployment* section). This path automates the supported-on-Linux pieces and the
> two things that otherwise break headless: Claude auth and persistent storage.

## What you get

- Node 20 + build tools, a dedicated unprivileged `claudeclaw` user, repo cloned +
  built, `.env` generated non-interactively.
- Dashboard bound to `127.0.0.1` (never on a public interface) and published to your
  tailnet at `https://<host>.<tailnet>.ts.net` via **Tailscale Serve**.
- `systemd` service with auto-restart + sandboxing.
- `ufw` (deny incoming, dashboard port never opened publicly), `fail2ban`,
  `unattended-upgrades`, and key-only SSH.

## Prerequisites

1. **A VPS** running Ubuntu 22.04+ or Debian 12+ with root SSH.
2. **Tailscale tailnet** with, in the admin console (`login.tailscale.com`):
   - **MagicDNS** enabled, and
   - **HTTPS certificates** enabled (Settings → Feature previews / DNS).
   Generate a **pre-auth key** (Settings → Keys) for an unattended join.
3. **Telegram bot**: create one with [@BotFather](https://t.me/BotFather), and get your
   numeric chat ID (e.g. via [@userinfobot](https://t.me/userinfobot)).
4. **Claude auth** — pick one:
   - **Max plan:** run `claude setup-token` on your laptop → long-lived OAuth token.
   - **Pay-per-token:** an `ANTHROPIC_API_KEY` from [console.anthropic.com](https://console.anthropic.com).
5. **Repo clone token** (the upstream `earlyaidopters/claudeclaw-os` repo is private):
   open the members token site, which shows a clone command like
   `git clone https://x-access-token:ghs_XXXX@github.com/...`. Copy the `ghs_...`
   token and set `REPO_CLONE_TOKEN` in the conf. Tokens expire in ~1h; regenerate and
   re-run if the clone step fails. (Skip if you point `REPO_URL` at a public repo.)

## Quickstart

From your laptop:

```bash
# Grab just the two files you need (or scp them from a local clone of the branch)
scp deploy/install-vps.sh deploy/claudeclaw-deploy.conf.example root@YOUR_VPS:/root/
ssh root@YOUR_VPS
```

On the VPS:

```bash
cp claudeclaw-deploy.conf.example claudeclaw-deploy.conf
nano claudeclaw-deploy.conf      # fill in the secrets
bash install-vps.sh
```

When it finishes it prints your dashboard URL, e.g.:

```
https://claudeclaw.tailXXXX.ts.net/?token=...&chatId=...
```

Open it on any device that's signed in to your tailnet. Then send a message from your
allowed Telegram chat to confirm the bot replies.

> Testing the feature branch before it's merged? Set `REPO_BRANCH=feat/vps-deploy-tailscale`
> in your conf so the VPS clones the same branch.

## Security model

| Layer | What it does |
|-------|--------------|
| Tailscale Serve | Only tailnet devices can reach the dashboard; valid HTTPS cert. |
| Loopback bind | Dashboard listens on `127.0.0.1` only — nothing on the public IP. |
| `DASHBOARD_TOKEN` | Per-request token (constant-time compared) even within the tailnet. |
| `ufw` | Deny incoming; dashboard port never opened; only SSH + `tailscale0` allowed. |
| `fail2ban` + key-only SSH | Brute-force protection on the one public service (SSH). |
| Unprivileged user + systemd sandbox | The bot (which spawns Claude Code) never runs as root. |

Nothing is exposed to the public internet — a public tunnel or an open port would weaken the
"authorized devices only" goal.

### SSH lockdown (optional)

`SSH_HARDENING=tailscale-only` blocks public port 22 so SSH only works over the tailnet.
Strongest, but only enable it once you've:

- **Disabled key expiry** on this node in the Tailscale admin console (otherwise the node
  drops off the tailnet after ~90 days and you lose SSH), and
- **Confirmed Hostinger's browser/VNC console** (hPanel → your VPS) works — it bypasses
  `ufw`/Tailscale entirely, so you can always recover with `ufw allow OpenSSH`.

## Day-2 operations

```bash
systemctl status claudeclaw          # service state
journalctl -u claudeclaw -f          # live logs
tailscale serve status               # confirm dashboard is published
systemctl restart claudeclaw         # restart after .env changes
```

Update to the latest code: re-run `bash install-vps.sh` (it `git reset --hard`s to the
configured branch, rebuilds, and restarts — your `.env`, `DASHBOARD_TOKEN`, and `store/`
are preserved).

Rotate the dashboard token:

```bash
sudo sed -i "s/^DASHBOARD_TOKEN=.*/DASHBOARD_TOKEN=$(openssl rand -hex 24)/" \
  /opt/claudeclaw/claudeclaw-os/.env
sudo systemctl restart claudeclaw
```

## Troubleshooting

- **`tailscale serve failed`** — HTTPS certs aren't enabled for your tailnet. Enable them
  in the admin console, then re-run the script.
- **Bot keeps restarting / Claude auth errors** — check the OAuth token / API key in
  `.env`; `journalctl -u claudeclaw -n 100`.
- **`better-sqlite3` build failure** — ensure `build-essential` + `python3` installed
  (the script installs them; on minimal images double-check apt succeeded).
- **A feature needs to write outside the install dir** — relax the systemd hardening
  (e.g. add a `ReadWritePaths=` entry) in `/etc/systemd/system/claudeclaw.service`,
  then `systemctl daemon-reload && systemctl restart claudeclaw`.

## Not covered by install-vps.sh

`install-vps.sh` provisions a **single-bot greenfield** box (one system-systemd
unit, `dist/index.js` with no `--agent`). It does NOT model a host that already
runs several agents, and re-running it would reset the firewall and rewrite `.env`.
For updating a live **multi-agent** host, use `update.sh` (below), not the installer.

War Room voice (`WARROOM_ENABLED`, needs a Python venv + `GOOGLE_API_KEY`) and
non-Debian distros remain out of scope.

---

# update.sh - safe update of a LIVE multi-agent host

`update.sh` is the repeatable update path for a host that already runs N agents
as **user** systemd units (`com.claudeclaw.agent-<name>.service`) with a live
SQLite store and per-agent state. It is deliberately narrow: it updates code and
restarts agents, and touches **nothing else** (no firewall, no secret rotation,
no Tailscale reconfigure).

What it does, in order, with an abort at every destructive step:

1. Preflight + **tess trading-window check** (won't proceed if a trade is in flight).
2. Stage a fresh clone of your fork at a dated dir.
3. Carry live `store/` + `.env` + `agents/` into the staged tree, and **verify the
   `DB_ENCRYPTION_KEY` hash matches** (else the encrypted DB would be unreadable - abort).
4. Back up the live DB + `.env` off the swap path.
5. `npm ci` + build the staged tree.
6. **Pre-swap gate (all hard aborts):** (a) open the carried-over live DB with the
   staged code's `better-sqlite3` (catches ABI/key mismatch), (b) `vitest` must pass,
   (c) **boot-probe** - start the entrypoint against the carried DB and require it to
   reach ready - all **before** the swap, so "builds but won't boot" never ships.
7. **Pause the cron watchdog** (else it relaunches OLD main mid-swap - split-brain).
8. Stop agents, **rename-swap** the dir (units reference the fixed path, so they pick
   up new code on restart), restart all agents with **tess last / only if idle**,
   relaunch tutor. Rollback on any failure = reverse rename.

## One-time setup (per host)

```bash
cp deploy/claudeclaw-update.conf.example deploy/claudeclaw-update.conf
nano deploy/claudeclaw-update.conf     # set RUN_USER, LIVE_DIR, REPO_URL, AGENTS, ...
```

The filled-in `claudeclaw-update.conf` is gitignored (may hold a clone token).

## The repeatable update (every time after)

```bash
ssh <host>
cd <LIVE_DIR>
# update.sh clones $REPO_BRANCH fresh into a dated dir - no manual fetch needed;
# set REPO_BRANCH in claudeclaw-update.conf to update from a branch other than main.
CLAUDECLAW_DEPLOY_CONF=deploy/claudeclaw-update.conf bash deploy/update.sh
bash deploy/smoke-all.sh
```

`smoke-all.sh` proves: all agents active, DB accepts a (rolled-back) write on the
new code, dashboard answers on loopback, watchdog un-paused. Exit 0 = green. After
green, **shred/remove the `.old-<stamp>` dir** (it holds a copy of `.env`) and the
backup once you no longer need the rollback point.
