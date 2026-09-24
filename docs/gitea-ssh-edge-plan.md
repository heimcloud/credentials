# Gitea SSH on port 2222 — edge plan (problem 1)

Status: **design + Neo diffs prepared; do not enable `sync.enable` on
customer machines until Fleet completes hattori + neohq steps below.**

## Root cause

Neo `nix/services/gitea` hard-codes `GITEA__server__DISABLE_SSH = "true"`.
Host port 22 on the public edge is the host sshd, not Gitea. Deploy keys
only work over SSH, so customer machines cannot `git fetch` today (only a
same-host local remote works on the forge host).

Box probe (2026-09-24 CEST): `git.heimcloud.site:443/80/2223/22` open;
**`:2222` closed/filtered**.

## Chosen approach

Enable Gitea **built-in SSH** on a dedicated port **2222**, advertise
`SSH_DOMAIN=git.heimcloud.site` / `SSH_PORT=2222`, publish the container port
to `127.0.0.1:2222` on the forge host (hattori), and tunnel that TCP port
through the existing **rathole → neohq streamproxy** path (new public listen
on neohq `:2222`).

Customer clone URL shape:

```text
ssh://git@git.heimcloud.site:2222/customers/<slug>.git
```

### Alternative considered (HTTPS + per-customer tokens)

- Gitea deploy keys are **SSH-only**; HTTPS would need per-customer
  access tokens (or collaborator accounts), which is a different trust
  model, harder rotation, and easier to leak into CI logs.
- Keep HTTPS for humans/API; keep **deploy keys over SSH** for machines.

## Exact Neo diffs (repo `madebydamo/neo` / fork `heimcloud/neo`)

### 1. `nix/services/gitea/option.nix` — add `ssh` submodule

```nix
ssh = {
  enable = mkEnableOption "Gitea built-in SSH server (deploy keys)" {rank = 0;};
  port = mkOption {
    type = types.port;
    default = 2222;
    description = "SSH_PORT advertised in clone URLs / UI";
    rank = 10;
  };
  listenPort = mkOption {
    type = types.port;
    default = 2222;
    description = "Host loopback port published as 127.0.0.1:listenPort → container :22";
    rank = 20;
  };
  domain = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = "SSH_DOMAIN; default = hostname derived from rootUrl / customDomains";
    rank = 30;
  };
};
```

### 2. `nix/services/gitea/default.nix` — when `cfg.ssh.enable`

- Remove / stop setting `GITEA__server__DISABLE_SSH = "true"`.
- Set:
  - `GITEA__server__START_SSH_SERVER = "true"`
  - `GITEA__server__SSH_PORT = toString cfg.ssh.port`
  - `GITEA__server__SSH_LISTEN_PORT = "22"` (inside container)
  - `GITEA__server__SSH_DOMAIN = <domain>`
- Publish ports: `"127.0.0.1:${toString cfg.ssh.listenPort}:22"`
- Keep HTTP only on the Docker `internal` network (SWAG unchanged).

### 3. `nix/services/rathole/option.nix` + `default.nix` — extra TCP services

```nix
extraServices = mkOption {
  type = types.attrsOf (types.submodule {
    options.localAddr = mkOption {
      type = types.str;
      description = "Client-side local_addr (e.g. 127.0.0.1:2222)";
    };
  });
  default = {};
  description = "Additional rathole client services beyond _http/_https";
};
```

Emit for each name:

```toml
[client.services.${cfg.name}_${name}]
token = "…"
local_addr = "…"
```

Forge host settings example:

```toml
[services.rathole.extraServices.gitea_ssh]
localAddr = "127.0.0.1:2222"
```

### 4. `nix/services/streamproxy/option.nix` + `default.nix` — public TCP forward

```nix
tcpForwards = mkOption {
  type = types.attrsOf (types.submodule {
    options = {
      entry = mkOption { type = types.str; description = "streamproxy.entries.<name>"; };
      serviceSuffix = mkOption { type = types.str; example = "gitea_ssh"; };
      listenPort = mkOption { type = types.port; example = 2222; };
    };
  });
  default = {};
};
```

For each forward, add rathole **server** service:

```toml
[server.services.${entry}_${serviceSuffix}]
token = "<entry.token>"
bind_addr = "0.0.0.0:${listenPort}"   # or 127.0.0.1 + socat like :80/:443
```

Also:

- `networking.firewall.allowedTCPPorts` += listenPort
- container `forwardPorts` / nginx stream container firewall allow list += listenPort
- optional `streamproxy-local<port>` socat unit if binding via 127.0.0.1 inside the container namespace

neohq settings example:

```toml
[services.streamproxy.tcpForwards.gitea_ssh]
entry = "damo"          # hattori's streamproxy entry name
serviceSuffix = "gitea_ssh"
listenPort = 2222
```

## Fleet steps (hattori + neohq) — after Neo PR is merged / branched tip activated

**Do not apply from this agent. No live host changes here.**

1. **Decision (Damo):** confirm opening **public TCP 2222** on neohq (new
   internet-facing port). Alternative: keep SSH forge internal-only (VPN /
   Tailscale) — then customer machines off-tailnet still cannot pull.
2. **hattori (forge):**
   - Activate Neo tip with gitea `ssh.enable = true` (port 2222).
   - Set `rathole.extraServices.gitea_ssh.localAddr = "127.0.0.1:2222"`.
   - Confirm `ss -lctn | grep 2222` on loopback; `docker port` / podman shows map.
   - Capture host key for pinning (on hattori, against local listener):
     `ssh-keyscan -p 2222 127.0.0.1` → store as `sync.knownHosts` on customers
     (also verify the same key via neohq once tunneled).
3. **neohq (edge):**
   - Activate Neo tip with `streamproxy.tcpForwards.gitea_ssh` as above.
   - Confirm public `git.heimcloud.site:2222` accepts TCP and speaks SSH
     (`ssh-keyscan -p 2222 git.heimcloud.site`).
   - Firewall / security group allows 2222/tcp from the internet (or a
     restricted set if Damo prefers).
4. **Pin known_hosts** on each customer Neo (`sync.knownHosts`) before
   enabling `neo.services.credentials.sync.enable`.
5. **Only then** set `sync.enable = true` with `customerRepoSlug` + `syncDir`
   (e.g. appdata `credentials-sync`) on lab machines (hattori/thatch). Never
   agwanti unless explicitly requested.

## SSH host-key pinning

- Gitea built-in SSH uses keys under the container `/data/ssh/` (persisted in
  appdata). First boot generates them; treat rotation as an incident (update
  every customer `knownHosts`).
- Customers use `StrictHostKeyChecking=yes` + `UserKnownHostsFile` pointing at
  the pinned file from `sync.knownHosts` (see credentials plugin sync unit).

## Credentials plugin coupling

- `neo.services.credentials.sync.remotePort` defaults to **2222**.
- `sync.enable` defaults to **false** until this edge work is done.
