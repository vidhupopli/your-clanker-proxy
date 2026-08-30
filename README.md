# your-clanker-proxy

A small AWS proxy you run yourself, for **Grok**, **OpenCode**, and **Cursor CLI**.

Portable Terraform (OpenTofu works too) plus Docker Compose. One **t4g.nano** in **ap-south-1**, one Elastic IP, public TCP **443**. Two client paths on that same port (this is **not** XOR), plus optional password **SSH 22** for a local tunnel:

| Client | How it gets out | Where the keys live |
| --- | --- | --- |
| **Cursor CLI** (`cursor-agent`) | HTTP CONNECT | Cursor login stays on your laptop. Cursor CLI cannot use BYOK or a custom OpenAI base URL, so it does **not** use the reverse gateway. |
| **Grok** (grok build) | Reverse gateway `/xai/v1` | xAI key stays on the server. Grok sends `gateway_token`. Config: `~/.grok/config.toml`. |
| **OpenCode** | Reverse gateway `/openrouter/api/v1` | OpenRouter key stays on the server. OpenCode sends `gateway_token`. Config: `~/.config/opencode/opencode.json`. |

Manage it with **`./proxy.sh`**. Do not paste raw `terraform apply` unless you are debugging.

Username **`starman`**, listen port **443**. Cost in Mumbai is about **$6.40/month**; the gateway is **~$0 extra** (same instance, same EIP, same 443).

## Two ways to use the box

CONNECT and the HTTP gateway both hit **TCP 443** on the EIP. Optional password SSH on **22** (same `allowed_cidrs` as 443) local-forwards 443 to `127.0.0.1:1443`.

Cleartext HTTP on 443 stays exactly as today (`http://EIP:443/...`, `http://127.0.0.1:1443/...`). **HTTPS is also on 443** (TLS vs HTTP mux — not SSH mux).

Set `domain_name` (and `acme_email`) in gitignored `terraform.tfvars` to issue a **Let’s Encrypt** cert via **Route53 DNS-01** (lego on the instance). Then HTTPS is `https://DOMAIN/xai/v1` with the **public CA** — no custom CA file. Empty `domain_name` keeps today’s **self-signed** cert (no hostname). Trust `./proxy.sh ca` (`NODE_EXTRA_CA_CERTS` / `SSL_CERT_FILE` / `curl --cacert`) only for that self-signed / HTTPS-by-IP path. Grok/OpenCode/Node fail verify without it. Zscaler (or similar) SSL inspection can still replace the issuer; apps that do not trust the interceptor CA see an untrusted issuer even when Let’s Encrypt is public.

### 1. HTTP CONNECT (default — Cursor CLI; login stays on your laptop)

`HTTP_PROXY=http://starman:PASS@EIP:443`. 3proxy publishes host 443. Destination whitelist + Basic auth. This is the whole box when `xai_api_key` and `openrouter_api_key` are empty.

### 2. HTTP reverse gateway (optional — Grok and OpenCode; server holds vendor keys)

Set one or both keys in **gitignored** `terraform.tfvars` and run `./proxy.sh setup`. HAProxy muxes public 443:

| Peek | Action |
| --- | --- |
| TLS ClientHello | Terminate TLS on HAProxy (loopback `:4443`), then the same CONNECT vs gateway split |
| plaintext `CONNECT` | TCP-forward to 3proxy on `127.0.0.1:3128` (same CONNECT auth/whitelist as today; 3proxy does **not** bind host 443) |
| `GET/POST /xai/...` | Strip `/xai`, `Host: api.x.ai`, inject xAI Bearer, SSE idle ≥ 30 min |
| `GET/POST /openrouter/...` | Strip `/openrouter` so `/openrouter/api/v1` → `/api/v1`, inject OpenRouter Bearer |
| anything else HTTP | **404** (not a generic HTTP forward proxy) |

Gateway clients send `Authorization: Bearer <gateway_token>` (a **new** SSM secret, not the CONNECT password). HAProxy deletes that header and sets the vendor Bearer. **401** otherwise.

```text
Grok     base_url  http://EIP:443/xai/v1              api_key=gateway_token
OpenCode baseURL   http://EIP:443/openrouter/api/v1   apiKey=gateway_token
# HTTPS with domain_name (Let's Encrypt public CA; no custom CA file):
Grok     base_url  https://DOMAIN/xai/v1
OpenCode baseURL   https://DOMAIN/openrouter/api/v1
# HTTPS by IP / empty domain_name (self-signed; trust ./proxy.sh ca):
Grok     base_url  https://EIP:443/xai/v1
OpenCode baseURL   https://EIP:443/openrouter/api/v1
```

`HTTP_PROXY` still works through the mux (cleartext `http://` CONNECT; Cursor stays on that). Put the EIP (and `domain_name` when set) in `NO_PROXY` so `http://EIP:443/xai/...` is not sent as CONNECT. The EIP URL **must** include `:443` — SG/HAProxy listen only on TCP 443; `http://EIP/xai/...` (port 80) times out. DNS-01 does not open port 80. Clients that speak an HTTPS proxy can use `https://starman:PASS@EIP:443` (trust the cert, or the public CA when `domain_name` is set). `./proxy.sh instructions` prints the full setup manual.

Cursor stays on CONNECT. Cost is ~$0 extra.

## Usage

You need Terraform ≥ 1.6 (or OpenTofu), AWS credentials, and `python3`. `AWS_PROFILE`, `AWS_REGION`, and `TF_VAR_region` are respected. Default region is `ap-south-1`.

```bash
export AWS_PROFILE=your-profile   # optional
./proxy.sh setup                  # CONNECT-only until you add keys
./proxy.sh status
./proxy.sh smoke
# optional gateway:
#   edit terraform.tfvars  xai_api_key / openrouter_api_key
./proxy.sh setup
./proxy.sh instructions
./proxy.sh smoke-gateway
./proxy.sh tunnel start        # optional: ssh -N -f local 1443 (password, then background; bare tunnel prints start|status|stop)
```

| Command | What it does |
| --- | --- |
| `./proxy.sh setup` (`apply`, `up`) | `terraform apply -auto-approve`, then write the zshrc CONNECT block |
| `./proxy.sh destroy` | Destroy if this stack exists; remove the zshrc block. No-op exit 0 if nothing is set up |
| `./proxy.sh zshrc` (`env`, `repair`) | Rewrite the local zshrc CONNECT block from terraform outputs |
| `./proxy.sh client` (`snippet`) | Print CONNECT-only exports for a restricted machine `.zshrc` / `.bashrc` |
| `./proxy.sh instructions` | Print the full setup manual: CONNECT exports, `GATEWAY_API_KEY`, Grok toml, OpenCode json, HTTP+HTTPS, SSH tunnel |
| `./proxy.sh ca` (`cert`) | Write the self-signed public cert from terraform output (default `./gateway-tls-cert.pem`) |
| `./proxy.sh status` | EIP, instance, region, **gateway on/off**, **tls on/off**, **ssh on/off** (no secrets), zshrc present/stale |
| `./proxy.sh smoke` | CONNECT to `https://api2.cursor.sh`. Fails on 403 or connection refused |
| `./proxy.sh smoke-gateway` | `GET http://EIP:443/xai/v1/models` (and HTTPS: public CA by hostname, or `--cacert` for self-signed) and `/openrouter/api/v1/models` with Bearer. Fails on 401/403/404 or connection refused |
| `./proxy.sh tunnel` | Print `start`/`status`/`stop` usage. Does not exec ssh |
| `./proxy.sh tunnel start` | Print and exec `ssh -N -f -L 1443:127.0.0.1:443` (password prompt; CONNECT password). No-op exit 0 if 1443 is already listening. Silence after the password means the tunnel is up; `-f` daemonizes so Ctrl-C does not apply (`./proxy.sh tunnel stop`). Exits if `ssh_enabled` is false |
| `./proxy.sh tunnel status` | Report whether local 1443 is forwarded: up/down, pid(s), listen address. Exit 0 if up, 1 if down. Reports a leftover tunnel even when `ssh_enabled` is false |
| `./proxy.sh tunnel stop` | Kill only the `ssh -L 1443:127.0.0.1:443` client (not github/unrelated ssh). Exit 0 if already down |
| `./proxy.sh ssm` | Print and exec `aws ssm start-session` |
| `./proxy.sh help` | Default if you pass no args |

If `terraform.tfvars` is missing, `setup` copies the example with `proxy_user = "starman"` and empty `allowed_cidrs` (roaming).

`HTTPS_PROXY` still uses the **`http://` scheme** (CONNECT, then origin TLS). Cursor does not need the self-signed cert for that path.

### Restricted computer

On a laptop that cannot run Terraform, copy stdout from a machine that has this repo's state:

- `./proxy.sh client` — CONNECT-only exports for `~/.zshrc` / `~/.bashrc`
- `./proxy.sh instructions` — full setup manual (shell, Grok `config.toml`, OpenCode `opencode.json`, HTTP+HTTPS, SSH tunnel)
- `./proxy.sh ca` — self-signed public cert to trust for HTTPS

### InsufficientInstanceCapacity

EC2 create times out after **8 minutes** (not the ~30m AWS default). `ap-south-1a` is often capacity-constrained for `t4g.nano`. If `./proxy.sh setup` fails with `InsufficientInstanceCapacity`, set in `terraform.tfvars`:

```hcl
availability_zone = "ap-south-1b"
```

(or `ap-south-1c`) and run `./proxy.sh setup` again. When unset, the public subnet AZ is chosen from `aws_ec2_instance_type_offerings` for `var.instance_type`: `sort(locations)` and index `1` if more than one AZ offers the type, else `0` (skips dry `1a` when `1b`/`1c` exist). Existing subnets ignore AZ changes so a live `ap-south-1a` subnet is not replaced.

### Switching accounts

New credentials + **separate state per account** + `./proxy.sh setup`. The EIP **will change**.

## Security model

Port 443 is **world-reachable** so you can roam.

CONNECT gates: **starman password** + **destination whitelist**.

Gateway gates: **gateway_token** Bearer + path allowlist (`/xai/`, `/openrouter/` only) + vendor keys that never leave the instance.

Password SSH (default on): TCP **22** from the same CIDRs as 443 (`allowed_cidrs` empty ⇒ `0.0.0.0/0`). Auth is **password only** for `proxy_user` (default `starman`) — same password as CONNECT, stored in SSM. No EC2 key pair, no `authorized_keys`. `AllowTcpForwarding yes`, `PermitRootLogin no`. Use `./proxy.sh tunnel start|status|stop` (`start` is `ssh -N -f -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o PreferredAuthentications=password -o PubkeyAuthentication=no -L 1443:127.0.0.1:443 USER@EIP`; password prompt; no sshpass). After the password, silence means the tunnel is up; Ctrl-C does not apply once `-f` daemonizes (`./proxy.sh tunnel stop`). Then Grok/OpenCode at `http://127.0.0.1:1443/...` (HTTPS on the tunnel only matches the self-signed SAN `127.0.0.1`; Let’s Encrypt SAN is the public hostname, not loopback) and CONNECT `HTTP_PROXY` to `127.0.0.1:1443`. Put `127.0.0.1,localhost` in `NO_PROXY`. Direct EIP URLs stay on **:443**. SSM Session Manager still works (`./proxy.sh ssm`). Set `ssh_enabled = false` to close 22.

## Adding a CONNECT destination

Add the host to `proxy_allow_dests` in `terraform.tfvars` and `./proxy.sh setup`. Changing user-data **replaces the instance**; the EIP stays on the ENI.

## Client environment

### Cursor CLI (CONNECT only)

`HTTP_PROXY`, `HTTPS_PROXY`, `NODE_USE_ENV_PROXY=1`. If streams stall, `network.useHttp1ForAgent` in `~/.cursor/cli-config.json`. Grok’s installer may overwrite `~/.local/bin/agent` — use **`cursor-agent`**.

### OpenCode

CONNECT: `HTTP_PROXY` / `HTTPS_PROXY` plus `NO_PROXY=localhost,127.0.0.1` (zshrc also has `::1`).

Gateway: merge `provider.openrouter.options` (`baseURL=http://EIP:443/openrouter/api/v1` or `https://DOMAIN/openrouter/api/v1` when `domain_name` is set, `apiKey={env:GATEWAY_API_KEY}`) into existing `opencode.json`. For Let’s Encrypt HTTPS, no custom CA file. For HTTPS-by-IP / self-signed, point `NODE_EXTRA_CA_CERTS` / `SSL_CERT_FILE` at `./proxy.sh ca`. Do not replace the whole file. This keeps OpenRouter's full model catalog; requests go to the box; HAProxy injects the real OpenRouter key. Do not `/connect` with the real `sk-or` key for this path. `./proxy.sh instructions` prints the json snippet to merge.

### Grok

CONNECT: `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY`. Idle ≥ 10 minutes (configured 30).

Gateway custom model: `base_url=http://EIP:443/xai/v1` (or `https://DOMAIN/xai/v1` with Let’s Encrypt / public CA, or `https://EIP:443/xai/v1` with `NODE_EXTRA_CA_CERTS` for self-signed), `api_backend=chat_completions`, `api_key=gateway_token`. Do **not** set `GROK_CLI_CHAT_PROXY_BASE_URL` to this box. `./proxy.sh instructions` prints the full toml block to append.

### Smoke

```bash
./proxy.sh smoke
./proxy.sh smoke-gateway   # only when a vendor key is set
```

## What Terraform creates

- Dedicated tiny VPC (not the account default): one public subnet, IGW
- Amazon Linux 2023 ARM (`t4g.nano`), AMI from `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64`
- One Elastic IP on a dedicated ENI (no second auto-assigned public IPv4)
- Docker Compose: 3proxy always; HAProxy only when a vendor key is set. Images pinned by **linux/arm64 digest**
- CONNECT: username `starman`, dest whitelist, idle 30 min, no SOCKS, no MITM. Cfg bind `:ro`, chmod **0644**, **no** `read_only`
- Gateway (optional): HAProxy on public 443, TLS terminated on loopback `:4443`. Self-signed cert in SSM is bootstrap/fallback. When `domain_name` is set, lego issues Let’s Encrypt via Route53 DNS-01 on the instance (renewal is a daily systemd timer — not terraform apply)
- Secrets in SSM SecureString, injected at boot or via SSM association. Not in git, not in AMI, not in EC2 user-data
- IAM: **AmazonSSMManagedInstanceCore**. When `domain_name` is set, an inline policy on the instance role allows Route53 DNS-01 (Change/List on that hosted zone, GetChange, ListHostedZones). IMDSv2, hop limit 2
- SG: ingress 443 from `0.0.0.0/0` (or `allowed_cidrs`); ingress 22 from the same CIDRs when `ssh_enabled`
- Password SSH: `aws_ssm_document` + `aws_ssm_association` enable sshd, ensure `proxy_user`, set password from the CONNECT SSM parameter, write `/etc/ssh/sshd_config.d/99-password.conf`. Not in user-data (would replace the instance)
- Gateway TLS: `hashicorp/tls` self-signed cert (SAN: EIP, `127.0.0.1`, `localhost`) stored as HAProxy PEM in SSM (always, as bootstrap). A second SSM association writes `haproxy.pem` + mux cfg + compose mount and `docker compose up -d` in-place so this apply does not replace the nano. With `domain_name`, that association also installs lego, issues/renews Let’s Encrypt, and prefers the public-CA pem
- Route53: public A record (TTL 60) for `domain_name` → EIP when set. No ALIAS. No SG 80
- 8 GB encrypted gp3

## Variables

| Name | Default | Notes |
| --- | --- | --- |
| `region` | `ap-south-1` | Overrideable |
| `instance_type` | `t4g.nano` | ARM |
| `availability_zone` | `""` | Empty: offerings data, skip first lexical AZ (`1a` often dry). Set `ap-south-1b`/`1c` on InsufficientInstanceCapacity |
| `allowed_cidrs` | `[]` | Optional SG restrictor. Empty = `0.0.0.0/0` |
| `proxy_user` | `starman` | CONNECT username |
| `proxy_port` | `443` | Public listen port |
| `name` | `dev-proxy` | Name prefix |
| `proxy_allow_dests` | Cursor / Grok / OpenCode hosts | CONNECT whitelist |
| `proxy_allow_all_dests` | `false` | Skip dest whitelist |
| `xai_api_key` | `""` (sensitive) | Non-empty enables `/xai/` + mux |
| `openrouter_api_key` | `""` (sensitive) | Non-empty enables `/openrouter/` + mux |
| `ssh_enabled` | `true` | TCP 22 + persist password SSH via SSM association |
| `domain_name` | `""` | Public DNS name for Let’s Encrypt (Route53 DNS-01). Empty = self-signed on the EIP |
| `acme_email` | `""` | Let’s Encrypt account email. Required when `domain_name` is set |

## Outputs

| Name | Sensitive | Meaning |
| --- | --- | --- |
| `eip_public_ip` | no | Client host |
| `instance_id` | no | EC2 id |
| `region` | no | AWS region |
| `gateway_enabled` | no | Mux on/off |
| `gateway_xai_base_url` | no | `http://EIP:443/xai/v1` or null |
| `gateway_openrouter_base_url` | no | `http://EIP:443/openrouter/api/v1` or null |
| `gateway_xai_base_url_https` | no | `https://DOMAIN/xai/v1` when `domain_name` is set, else `https://EIP:443/xai/v1`, or null |
| `gateway_openrouter_base_url_https` | no | `https://DOMAIN/openrouter/api/v1` when `domain_name` is set, else `https://EIP:443/openrouter/api/v1`, or null |
| `gateway_tls_cert_pem` | no | Self-signed public server cert (PEM) for the empty-domain path. Not the private key. Public CA when `domain_name` is set |
| `domain_name` | no | Public DNS name, or empty |
| `gateway_tls_ca_pem` | no | Same bytes as `gateway_tls_cert_pem` (for `--cacert`) |
| `http_proxy_url` | **yes** | `http://starman:PASS@EIP:443` |
| `https_proxy_export_snippet` | **yes** | macOS zsh CONNECT exports |
| `gateway_token` | **yes** | Gateway Bearer |
| `ssm_start_session_command` | no | SSM attach |
| `ssh_enabled` | no | Password SSH on/off |
| `ssh_tunnel_command` | no | `ssh -N -f -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o PreferredAuthentications=password -o PubkeyAuthentication=no -L 1443:127.0.0.1:443 USER@EIP` |

## Layout

```
proxy.sh
versions.tf  providers.tf  variables.tf  locals.tf  outputs.tf
vpc.tf  iam.tf  sg.tf  ec2.tf  eip.tf  dns.tf  ssm.tf  tls.tf
user_data.sh.tftpl
docker-compose.yml              # 3proxy; HAProxy when gateway on
config/3proxy.cfg.tftpl
config/haproxy.cfg.tftpl
config/configure-ssh.sh         # SSM association (password sshd)
config/configure-tls.sh.tftpl   # SSM association (cert + mux cfg in-place; lego when domain_name)
config/lego-renew.sh.tftpl      # daily systemd oneshot (lego renew --days 30)
Dockerfile                      # unused 3proxy fallback
terraform.tfvars.example
```
