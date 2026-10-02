# machine-bootstrap

Server provisioning scripts you fetch and run — no clone, no dependencies
beyond `curl`.

Every script is standalone and readable. You can run one by itself, or use the
all-in-one menu to pick several. Nothing is hidden behind an installer
framework: what you fetch is plain bash you can read before running.

```bash
# One tool, straight off the network
curl -fsSL https://raw.githubusercontent.com/fuunshi/machine-bootstrap/main/scripts/nginx.sh | sudo bash -s -- --branch mainline

# Or an interactive menu of everything
curl -fsSL https://raw.githubusercontent.com/fuunshi/machine-bootstrap/main/scripts/server-setup.sh | sudo bash
```

## What's in here

| Script | Installs | Choose |
|---|---|---|
| [`postgres.sh`](scripts/postgres.sh) | PostgreSQL | major version **16 / 17 / 18** |
| [`docker.sh`](scripts/docker.sh) | Docker Engine, buildx, compose plugin | channel **stable / test** |
| [`redis.sh`](scripts/redis.sh) | Redis | series **8** (current, AGPLv3) **/ 7.4** (last BSD) |
| [`nginx.sh`](scripts/nginx.sh) | nginx from nginx.org | branch **stable / mainline** |
| [`certbot.sh`](scripts/certbot.sh) | certbot + authenticator | method **snap / apt**, plugin **nginx / apache / none** |
| [`nvm.sh`](scripts/nvm.sh) | nvm + Node.js | **lts / latest / pinned version** |
| [`wormhole.sh`](scripts/wormhole.sh) | magic-wormhole | method **apt / pipx** |
| [`base.sh`](scripts/base.sh) | baseline server setup | upgrade, timezone, swap, UFW, user, SSH hardening |
| [`site-wizard.sh`](scripts/site-wizard.sh) | a domain over HTTPS | — |
| [`server-setup.sh`](scripts/server-setup.sh) | **the all-in-one menu** | — |

Supports **Ubuntu 22.04 / 24.04 / 26.04** and **Debian 12 / 13**, on amd64 and arm64.

## The three ways to run things

**A single tool.** Add `-s --` so your flags reach the script rather than bash:

```bash
curl -fsSL <url>/scripts/postgres.sh | sudo bash -s -- --version 17
```

**By name, via the dispatcher.** Same thing, shorter to remember:

```bash
curl -fsSL <url>/install.sh | sudo bash -s -- nginx --branch mainline
```

**The menu.** Pick any combination of tools, plus base prep and the HTTPS
wizard:

```bash
curl -fsSL <url>/scripts/server-setup.sh | sudo bash
```

```
  1) base      Base server prep — upgrade, timezone, swap, firewall, user, SSH
  2) postgres  PostgreSQL — 16, 17 or 18
  3) docker    Docker Engine + buildx + compose plugin
  4) redis     Redis — 8 (current) or 7.4 (last BSD-licensed line)
  5) nginx     nginx — stable or mainline
  6) certbot   certbot — snap or apt, with the nginx authenticator
  7) nvm       nvm + Node.js — LTS or latest
  8) wormhole  magic-wormhole — file transfer between machines
  9) wizard    Site wizard — serve a domain over HTTPS

  > 1 5 6 9
```

Unattended works too:

```bash
curl -fsSL <url>/scripts/server-setup.sh | sudo bash -s -- \
  --with nginx,certbot --domain example.com --email you@example.com --yes
```

## Pinning to a version

The `main` branch is a moving target. For anything you care about, pin to a tag
or commit so the code you audited is the code that runs:

```bash
export MB_BASE_URL=https://raw.githubusercontent.com/fuunshi/machine-bootstrap/v1.0.0
curl -fsSL $MB_BASE_URL/scripts/nginx.sh | sudo bash -s -- --branch mainline
```

`MB_BASE_URL` also points at a fork or a local server, which is how you test
changes before merging them.

## Things worth knowing

**Every script takes `--dry-run`, `--yes` and `--help`.** `--dry-run` prints
every command it would run and changes nothing:

```bash
curl -fsSL <url>/scripts/docker.sh | sudo bash -s -- --dry-run
```

**No arguments means "ask me" — unless there's nobody to ask.** With a terminal
attached you get prompted; piped or in CI, the recommended default is used and
logged, so an unattended run never hangs. Flags always win.

**Re-running is safe.** Each script detects an existing install and reports it
rather than reinstalling. `--force` overrides.

**The scripts that can lock you out are the careful ones.** `base.sh` allows the
SSH port *before* enabling the firewall, takes that port from `sshd -T` rather
than assuming 22, and refuses to disable password authentication unless a
sudo-capable account already has a working key — validating with `sshd -t` and
rolling back if it fails.

**certbot: pick one method.** snap and apt certbot each install a renewal timer
aimed at the same `/etc/letsencrypt`. Two of them racing is a real hazard, so
`certbot.sh` detects the other variant and asks before removing it.

**The site wizard owns your nginx config.** It uses `certbot certonly
--webroot` rather than letting `certbot --nginx` rewrite your server blocks,
which is neither idempotent nor reversible.

## Layout

```
machine-bootstrap/
├── install.sh              run any script by name
└── scripts/
    ├── lib/common.sh       shared helpers — logging, prompts, apt, detection
    ├── postgres.sh         ┐
    ├── docker.sh           │
    ├── redis.sh            │ one script per tool,
    ├── nginx.sh            │ each standalone and fetchable
    ├── certbot.sh          │
    ├── nvm.sh              │
    ├── wormhole.sh         │
    ├── base.sh             ┘  baseline server setup
    ├── site-wizard.sh      nginx + certbot for one domain
    └── server-setup.sh     the menu; runs the above, never reimplements them
```

`lib/common.sh` sits *beside* the scripts on purpose. Each script looks for
exactly one path — `lib/common.sh` next to itself — and downloads it from the
repo only if that's absent. A wider search would let a script sitting in `/tmp`
pick up an unrelated `lib/` that happened to be there.

`server-setup.sh` downloads the scripts it needs into a temp directory laid out
to mirror this one, so each child finds the library beside it and nothing is
fetched twice.

## Development

```bash
shellcheck -x install.sh scripts/*.sh scripts/lib/common.sh
bash -n scripts/*.sh
```

To test a change before pushing it, either run it from your checkout — the
scripts prefer a local `lib/` when one is present — or serve the directory and
point a container at it:

```bash
sudo ./scripts/nginx.sh --dry-run            # from the checkout

python3 -m http.server 8000 &                # or over HTTP, as a server sees it
docker run --rm --add-host=host.docker.internal:host-gateway ubuntu:24.04 \
  bash -c 'MB_BASE_URL=http://host.docker.internal:8000 \
           bash <(curl -fsSL $MB_BASE_URL/scripts/nginx.sh) --dry-run'
```

Dry runs only prove the logic. Real installs need a throwaway container:

```bash
docker run --rm -it -v "$PWD:/mnt:ro" ubuntu:24.04
# then, inside: bash /mnt/scripts/nginx.sh --yes
```

Note that a container has no systemd, so services are not started and the
scripts say so rather than failing. Test with a distro matching your target:
`ubuntu:22.04`, `ubuntu:24.04`, `ubuntu:26.04`, `debian:12`, `debian:13`.

## Licence

MIT
