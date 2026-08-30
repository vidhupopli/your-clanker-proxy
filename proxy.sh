#!/usr/bin/env bash
# Manage the AWS HTTP CONNECT proxy Terraform root in this directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

MARKER_BEGIN='# >>> aws-forward-proxy >>>'
MARKER_END='# <<< aws-forward-proxy <<<'

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  RED=$'\033[31m'
  RESET=$'\033[0m'
else
  BOLD= GREEN= YELLOW= RED= RESET=
fi

die() { echo "${RED}error:${RESET} $*" >&2; exit 1; }
info() { echo "$*"; }
ok() { echo "${GREEN}$*${RESET}"; }

TF=""
OUTPUT_JSON=""

ensure_tf() {
  if [[ -n "$TF" ]]; then
    return 0
  fi
  if command -v terraform >/dev/null 2>&1; then
    TF=terraform
  elif command -v tofu >/dev/null 2>&1; then
    TF=tofu
  else
    die "terraform or tofu not found in PATH"
  fi
}

tf() {
  ensure_tf
  "$TF" "$@"
}

load_outputs() {
  OUTPUT_JSON="$(tf output -json 2>/dev/null || echo '{}')"
}

# Print terraform output value for key. Empty if missing (old state).
out_get() {
  local key="$1"
  # macOS bash 3.2 treats ${VAR:-{}} as ${VAR:-{ plus a leftover },
  # which appends "}" onto terraform JSON and breaks json.loads.
  # Python already defaults empty OUTPUT_JSON to {}.
  OUTPUT_JSON="${OUTPUT_JSON-}" python3 - "$key" <<'PY'
import json
import os
import sys

key = sys.argv[1]
try:
    data = json.loads(os.environ.get("OUTPUT_JSON") or "{}")
except json.JSONDecodeError:
    data = {}
node = data.get(key) or {}
val = node.get("value") if isinstance(node, dict) else None
if val is None:
    print("")
elif isinstance(val, bool):
    print("true" if val else "false")
else:
    print(val)
PY
}

zshrc_path() {
  if [[ -n "${ZDOTDIR:-}" ]]; then
    printf '%s\n' "${ZDOTDIR}/.zshrc"
  else
    printf '%s\n' "${HOME}/.zshrc"
  fi
}

ca_pem_path() {
  printf '%s\n' "${HOME}/.config/aws-forward-proxy/ca.pem"
}

zshenv_path() {
  if [[ -n "${ZDOTDIR:-}" ]]; then
    printf '%s\n' "${ZDOTDIR}/.zshenv"
  else
    printf '%s\n' "${HOME}/.zshenv"
  fi
}

write_ca_pem() {
  local dest
  dest="$(ca_pem_path)"
  mkdir -p "$(dirname "$dest")"
  cmd_ca "$dest" >/dev/null
}

ensure_tfvars() {
  if [[ -f terraform.tfvars ]]; then
    return 0
  fi
  [[ -f terraform.tfvars.example ]] || die "terraform.tfvars.example is missing"
  cp terraform.tfvars.example terraform.tfvars
  if ! grep -Eq '^[[:space:]]*proxy_user[[:space:]]*=' terraform.tfvars; then
    printf '\nproxy_user    = "starman"\n' >>terraform.tfvars
  fi
  if ! grep -Eq '^[[:space:]]*allowed_cidrs[[:space:]]*=' terraform.tfvars; then
    printf 'allowed_cidrs = []\n' >>terraform.tfvars
  fi
  info "wrote terraform.tfvars (proxy_user=starman, allowed_cidrs=[] roaming)"
}

has_state_resources() {
  local list
  list="$(tf state list 2>/dev/null || true)"
  [[ -n "$list" ]]
}

has_outputs() {
  has_state_resources || return 1
  local ip
  ip="$(tf output -raw eip_public_ip 2>/dev/null || true)"
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  load_outputs
}

# Password-only local-forward of mux 443 onto 127.0.0.1:1443.
# Built here (not copied from terraform output) so -f is present even
# when state still has the older foreground ssh -N string.
ssh_tunnel_cmd() {
  local user="starman" eip ssh_cmd
  ssh_cmd="$(out_get ssh_tunnel_command)"
  if [[ "$ssh_cmd" =~ ([A-Za-z0-9._-]+)@ ]]; then
    user="${BASH_REMATCH[1]}"
  fi
  eip="${1:-}"
  if [[ -z "$eip" || "$eip" == "null" ]]; then
    eip="$(out_get eip_public_ip)"
  fi
  [[ -n "$eip" && "$eip" != "null" ]] || return 1
  printf 'ssh -N -f -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o PreferredAuthentications=password -o PubkeyAuthentication=no -L 1443:127.0.0.1:443 %s@%s\n' "$user" "$eip"
}

region_fallback() {
  local r
  r="$(out_get region)"
  if [[ "$r" =~ ^[a-z]{2}-[a-z0-9-]+-[0-9]+$ ]]; then
    printf '%s\n' "$r"
    return 0
  fi
  if [[ -n "${AWS_REGION:-}" ]]; then
    printf '%s\n' "$AWS_REGION"
    return 0
  fi
  if [[ -n "${AWS_DEFAULT_REGION:-}" ]]; then
    printf '%s\n' "$AWS_DEFAULT_REGION"
    return 0
  fi
  if [[ -n "${TF_VAR_region:-}" ]]; then
    printf '%s\n' "$TF_VAR_region"
    return 0
  fi
  if [[ -f terraform.tfvars ]]; then
    r="$(awk -F= '/^[[:space:]]*region[[:space:]]*=/{gsub(/[" ]/, "", $2); print $2; exit}' terraform.tfvars)"
    if [[ -n "$r" ]]; then
      printf '%s\n' "$r"
      return 0
    fi
  fi
  printf '%s\n' "ap-south-1"
}

# $1 = body to insert (empty = remove the managed block only)
rewrite_zshrc() {
  local path body begin end
  path="${PROXY_DOTFILE_PATH:-$(zshrc_path)}"
  begin="${PROXY_DOTFILE_BEGIN:-$MARKER_BEGIN}"
  end="${PROXY_DOTFILE_END:-$MARKER_END}"
  body="${1-}"
  command -v python3 >/dev/null 2>&1 || die "python3 is required to edit $path"
  PROXY_ZSHRC_BODY="$body" python3 - "$path" "$begin" "$end" <<'PY'
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
begin, end = sys.argv[2], sys.argv[3]
body = os.environ.get("PROXY_ZSHRC_BODY", "")
text = path.read_text() if path.exists() else ""
out = []
skip = False
for line in text.splitlines():
    if line == begin:
        skip = True
        continue
    if line == end:
        skip = False
        continue
    if not skip:
        out.append(line)
while out and out[-1] == "":
    out.pop()
if body.strip():
    if out:
        out.append("")
    out.append(begin)
    out.extend(body.strip("\n").splitlines())
    out.append(end)
    out.append("")
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text("\n".join(out) if out else "")
if out and not path.read_text().endswith("\n"):
    path.write_text(path.read_text() + "\n")
PY
}

no_proxy_value() {
  local eip gw domain hosts
  eip="$(out_get eip_public_ip)"
  gw="$(out_get gateway_enabled)"
  domain="$(out_get domain_name)"
  hosts="localhost,127.0.0.1,::1"
  if [[ "$gw" == "true" && -n "$eip" ]]; then
    hosts="${hosts},${eip}"
  fi
  if [[ -n "$domain" && "$domain" != "null" ]]; then
    hosts="${hosts},${domain}"
  fi
  printf '%s\n' "$hosts"
}

# Cleartext HTTP gateway shares the CONNECT mux port (var.proxy_port, default 443).
# Old terraform state printed http://EIP/xai/v1 (port 80). SG does not open 80.
mux_http_url() {
  local url="$1"
  [[ -n "$url" && "$url" != "null" ]] || { printf '%s\n' "$url"; return 0; }
  OUTPUT_JSON="${OUTPUT_JSON-}" python3 - "$url" <<'PY'
import json
import os
import sys
from urllib.parse import urlparse, urlunparse

url = sys.argv[1]
port = 443
try:
    data = json.loads(os.environ.get("OUTPUT_JSON") or "{}")
    proxy = ((data.get("http_proxy_url") or {}).get("value")) or ""
    parsed_proxy = urlparse(proxy)
    if parsed_proxy.port:
        port = parsed_proxy.port
except Exception:
    pass
u = urlparse(url)
if u.scheme == "http" and u.hostname and u.port is None:
    u = u._replace(netloc=f"{u.hostname}:{port}")
print(urlunparse(u))
PY
}

canonical_proxy_exports() {
  # Do not print this to stdout from setup/zshrc — it contains the CONNECT password
  # and, when the gateway is on, GATEWAY_API_KEY.
  local snippet url gw token domain ca_path
  snippet="$(tf output -raw https_proxy_export_snippet 2>/dev/null || true)"
  url="$(tf output -raw http_proxy_url 2>/dev/null || true)"
  [[ -n "$url" ]] || return 1
  gw="$(out_get gateway_enabled)"
  token=""
  if [[ "$gw" == "true" ]]; then
    token="$(tf output -raw gateway_token 2>/dev/null || true)"
  fi
  domain="$(out_get domain_name)"
  ca_path=""
  if [[ "$gw" == "true" && ( -z "$domain" || "$domain" == "null" ) ]]; then
    ca_path="$(ca_pem_path)"
  fi
  NO_PROXY_VALUE="$(no_proxy_value)" GATEWAY_TOKEN="$token" CA_PEM_PATH="$ca_path" python3 - "$url" "$snippet" <<'PY'
import os
import re
import sys

url, snippet = sys.argv[1], sys.argv[2]
http = url
m = re.search(r"HTTP_PROXY=['\"]([^'\"]+)['\"]", snippet or "")
if m:
    http = m.group(1)
no_proxy = os.environ.get("NO_PROXY_VALUE") or "localhost,127.0.0.1,::1"
print(f"export HTTP_PROXY='{http}'")
print('export HTTPS_PROXY="$HTTP_PROXY"')
print(f"export NO_PROXY='{no_proxy}'")
print("export NODE_USE_ENV_PROXY=1")
token = os.environ.get("GATEWAY_TOKEN") or ""
if token:
    print(f"export GATEWAY_API_KEY='{token}'")
ca = os.environ.get("CA_PEM_PATH") or ""
if ca:
    print(f"export NODE_EXTRA_CA_CERTS='{ca}'")
    print(f"export SSL_CERT_FILE='{ca}'")
    print(f"export GROK_EXTRA_CA_BUNDLE='{ca}'")
PY
}

write_zshenv_ca() {
  local dest body
  dest="$(ca_pem_path)"
  body="export NODE_EXTRA_CA_CERTS='${dest}'
export SSL_CERT_FILE='${dest}'
export GROK_EXTRA_CA_BUNDLE='${dest}'"
  PROXY_DOTFILE_PATH="$(zshenv_path)" PROXY_DOTFILE_BEGIN="# >>> aws-forward-proxy-ca >>>" PROXY_DOTFILE_END="# <<< aws-forward-proxy-ca <<<" rewrite_zshrc "$body"
}

write_zshrc_from_outputs() {
  has_outputs || die "no terraform outputs yet — run ./proxy.sh setup first"
  local domain body path
  domain="$(out_get domain_name)"
  body="$(canonical_proxy_exports)"
  rewrite_zshrc "$body"
  if [[ -z "$domain" || "$domain" == "null" ]]; then
    write_ca_pem
    write_zshenv_ca
    ok "wrote proxy env to $(zshrc_path)"
    info "wrote CA env to $(zshenv_path) (no secrets)"
  else
    path="$(zshenv_path)"
    if [[ -f "$path" ]] && grep -Fq "# >>> aws-forward-proxy-ca >>>" "$path" 2>/dev/null; then
      PROXY_DOTFILE_PATH="$path" PROXY_DOTFILE_BEGIN="# >>> aws-forward-proxy-ca >>>" PROXY_DOTFILE_END="# <<< aws-forward-proxy-ca <<<" rewrite_zshrc ""
      info "removed CA block from $path (Let's Encrypt public CA; no custom CA file)"
    fi
    ok "wrote proxy env to $(zshrc_path)"
    info "HTTPS uses Let's Encrypt; no custom CA file."
  fi
  info "open a new terminal or: source $(zshrc_path)"
  info "HTTPS_PROXY uses the http:// scheme (CONNECT, then origin TLS)."
}

remove_zshrc_block() {
  local path
  path="$(zshrc_path)"
  if [[ -f "$path" ]] && grep -Fq "$MARKER_BEGIN" "$path" 2>/dev/null; then
    rewrite_zshrc ""
    info "removed managed block from $path"
  fi
  path="$(zshenv_path)"
  if [[ -f "$path" ]] && grep -Fq "# >>> aws-forward-proxy-ca >>>" "$path" 2>/dev/null; then
    PROXY_DOTFILE_PATH="$path" PROXY_DOTFILE_BEGIN="# >>> aws-forward-proxy-ca >>>" PROXY_DOTFILE_END="# <<< aws-forward-proxy-ca <<<" rewrite_zshrc ""
    info "removed CA block from $path"
  fi
}

zshrc_block_text() {
  local path
  path="$(zshrc_path)"
  [[ -f "$path" ]] || return 1
  python3 - "$path" "$MARKER_BEGIN" "$MARKER_END" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
begin, end = sys.argv[2], sys.argv[3]
if not path.exists():
    raise SystemExit(1)
lines = path.read_text().splitlines()
capturing = False
block = []
for line in lines:
    if line == begin:
        capturing = True
        continue
    if line == end:
        capturing = False
        break
    if capturing:
        block.append(line)
if not block:
    raise SystemExit(1)
print("\n".join(block))
PY
}

zshrc_eip() {
  local block
  block="$(zshrc_block_text 2>/dev/null || true)"
  [[ -n "$block" ]] || return 1
  python3 -c 'import re,sys; m=re.search(r"@(\d+\.\d+\.\d+\.\d+):", sys.stdin.read()); sys.exit(1) if not m else print(m.group(1))' <<<"$block"
}

cmd_help() {
  cat <<EOF
${BOLD}./proxy.sh <command>${RESET}

  ${BOLD}setup${RESET} | apply | up     Create or update the proxy, then write the zshrc block
  ${BOLD}destroy${RESET}                Tear down AWS resources and remove the zshrc block
  ${BOLD}zshrc${RESET} | env | repair   Rewrite the local zshrc CONNECT block from terraform outputs
  ${BOLD}client${RESET} | snippet       Print CONNECT exports for a restricted machine .zshrc/.bashrc
  ${BOLD}instructions${RESET}          Setup manual: CONNECT, Grok/OpenCode, HTTP+HTTPS, SSH tunnel to 127.0.0.1:1443
  ${BOLD}ca${RESET} | cert              Write the self-signed public cert (terraform output) to a file
  ${BOLD}status${RESET}                 EIP, instance, region, gateway on/off, tls on/off, ssh on/off, zshrc
  ${BOLD}smoke${RESET}                  curl -I https://api2.cursor.sh through CONNECT
  ${BOLD}smoke-gateway${RESET}          GET /v1/models through the HTTP gateway (and HTTPS with --cacert)
  ${BOLD}tunnel${RESET}                 start|status|stop local 1443 SSH forward (bare tunnel prints usage)
  ${BOLD}ssm${RESET}                    Print and exec aws ssm start-session
  ${BOLD}help${RESET}                   This text

Username ${BOLD}starman${RESET}, public TCP ${BOLD}443${RESET}. CONNECT and the HTTP/HTTPS gateway share that port.
Password SSH ${BOLD}22${RESET} (same CIDRs) forwards 127.0.0.1:1443 to mux 443. SSM still works.
EOF
}

cmd_destroy() {
  if ! has_state_resources; then
    info "nothing to destroy (no terraform state resources)"
    remove_zshrc_block
    exit 0
  fi
  tf destroy -auto-approve -input=false
  remove_zshrc_block
  ok "destroyed"
}

cmd_setup() {
  ensure_tfvars
  tf init -input=false
  tf apply -auto-approve -input=false
  write_zshrc_from_outputs
}

cmd_zshrc() {
  write_zshrc_from_outputs
}

cmd_client() {
  has_outputs || die "no terraform outputs yet — run ./proxy.sh setup first"
  # CONNECT-only block for a restricted machine's .zshrc / .bashrc (stdout).
  canonical_proxy_exports
}

cmd_status() {
  local ip id region zshrc_ip path gw xai ortr
  path="$(zshrc_path)"
  if ! has_outputs; then
    info "apply status: not applied (no outputs). run ./proxy.sh setup"
    if [[ -f "$path" ]] && grep -Fq "$MARKER_BEGIN" "$path" 2>/dev/null; then
      info "zshrc: managed block present but terraform has no EIP (stale)"
    else
      info "zshrc: no managed block"
    fi
    return 0
  fi
  ip="$(out_get eip_public_ip)"
  id="$(out_get instance_id)"
  region="$(region_fallback)"
  gw="$(out_get gateway_enabled)"
  xai="$(out_get gateway_xai_enabled)"
  ortr="$(out_get gateway_openrouter_enabled)"
  info "eip        $ip"
  info "instance   $id"
  info "region     $region"
  if [[ -z "$gw" ]]; then
    info "gateway    off (output missing; old state)"
  elif [[ "$gw" == "true" ]]; then
    local bits=()
    [[ "$xai" == "true" ]] && bits+=(xai)
    [[ "$ortr" == "true" ]] && bits+=(openrouter)
    if [[ "${#bits[@]}" -eq 0 ]]; then
      info "gateway    on"
    else
      info "gateway    on (${bits[*]})"
    fi
  else
    info "gateway    off"
  fi
  if command -v aws >/dev/null 2>&1; then
    local aws_st
    if aws_st="$(aws ec2 describe-instance-status \
      --instance-ids "$id" \
      --include-all-instances \
      --region "$region" \
      --query 'InstanceStatuses[0].{State:InstanceState.Name,System:SystemStatus.Status,Instance:InstanceStatus.Status}' \
      --output text 2>/dev/null)"; then
      info "aws        $aws_st"
    else
      info "aws: could not describe-instance-status (creds/region?)"
    fi
  else
    info "aws: CLI not in PATH"
  fi
  local tls_cert domain
  domain="$(out_get domain_name)"
  tls_cert="$(out_get gateway_tls_cert_pem)"
  if [[ -n "$domain" && "$domain" != "null" ]]; then
    info "domain     $domain"
    info "tls        on (Let's Encrypt public CA; no custom CA file)"
  elif [[ -n "$tls_cert" && "$tls_cert" != "null" ]]; then
    info "tls        on (self-signed; ./proxy.sh ca)"
  else
    info "tls        off"
  fi
  local ssh_en ssh_cmd
  ssh_en="$(out_get ssh_enabled)"
  ssh_cmd="$(out_get ssh_tunnel_command)"
  if [[ "$ssh_en" == "true" ]]; then
    if [[ -n "$ssh_cmd" && "$ssh_cmd" != "null" ]]; then
      info "ssh        on  ($ssh_cmd)"
    else
      info "ssh        on  (./proxy.sh tunnel start)"
    fi
  elif [[ "$ssh_en" == "false" ]]; then
    info "ssh        off"
  else
    info "ssh        (output missing; old state — password SSH may still be live)"
  fi
  if zshrc_ip="$(zshrc_eip 2>/dev/null)"; then
    if [[ "$zshrc_ip" == "$ip" ]]; then
      ok "zshrc: managed block present, EIP matches"
    else
      echo "${YELLOW}zshrc: stale EIP ${zshrc_ip} (terraform ${ip}) — run ./proxy.sh zshrc${RESET}"
    fi
  else
    echo "${YELLOW}zshrc: managed block missing — run ./proxy.sh zshrc${RESET}"
  fi
}

cmd_smoke() {
  has_outputs || die "no terraform outputs yet — run ./proxy.sh setup first"
  local url origin connect rc=0 out
  url="$(tf output -raw http_proxy_url)"
  set +e
  out="$(curl -sS -I --connect-timeout 15 --max-time 30 \
    -x "$url" \
    -o /dev/null \
    -w 'origin=%{http_code} connect=%{http_connect}' \
    https://api2.cursor.sh 2>&1)"
  rc=$?
  set -e
  origin="$(sed -n 's/.*origin=\([0-9]*\).*/\1/p' <<<"$out" | tail -n1)"
  connect="$(sed -n 's/.*connect=\([0-9]*\).*/\1/p' <<<"$out" | tail -n1)"
  if [[ "$rc" -ne 0 ]]; then
    die "smoke failed (curl exit ${rc}; connection refused or timeout)"
  fi
  if [[ "$connect" == "403" || "$origin" == "403" ]]; then
    die "smoke failed (403)"
  fi
  if [[ "$origin" == "407" || "$connect" == "407" ]]; then
    die "smoke failed (407 proxy auth)"
  fi
  if [[ "$connect" == "200" || "$origin" =~ ^[23][0-9][0-9]$ ]]; then
    ok "CONNECT ok (connect=${connect:-?} origin=${origin})"
    return 0
  fi
  die "smoke failed (connect=${connect:-?} origin=${origin})"
}


cmd_ca() {
  has_outputs || die "no terraform outputs yet — run ./proxy.sh setup first"
  local dest
  dest="${1:-$ROOT/gateway-tls-cert.pem}"
  if ! tf output -raw gateway_tls_cert_pem >"$dest" 2>/dev/null; then
    rm -f "$dest"
    die "gateway_tls_cert_pem is empty (gateway off?)"
  fi
  if ! grep -q "BEGIN CERTIFICATE" "$dest"; then
    rm -f "$dest"
    die "gateway_tls_cert_pem is empty (gateway off?)"
  fi
  chmod 0644 "$dest"
  ok "wrote $dest"
  info "HTTPS clients: curl --cacert $dest"
  info "Node/Grok/OpenCode: NODE_EXTRA_CA_CERTS=$dest  and/or  SSL_CERT_FILE=$dest"
  info "Without this file, HTTPS verify fails. Zscaler can still MITM if the OS trusts the interceptor CA."
}

cmd_client_instructions() {
  has_outputs || die "no terraform outputs yet — run ./proxy.sh setup first"
  local gw eip token xai_url or_url exports domain xai_https or_https
  gw="$(out_get gateway_enabled)"
  [[ "$gw" == "true" ]] || die "gateway is off; set xai_api_key and/or openrouter_api_key in terraform.tfvars, then ./proxy.sh setup"
  eip="$(out_get eip_public_ip)"
  token="$(tf output -raw gateway_token)"
  xai_url="$(mux_http_url "$(out_get gateway_xai_base_url)")"
  or_url="$(mux_http_url "$(out_get gateway_openrouter_base_url)")"
  domain="$(out_get domain_name)"
  xai_https="$(out_get gateway_xai_base_url_https)"
  or_https="$(out_get gateway_openrouter_base_url_https)"
  exports="$(canonical_proxy_exports)"
  echo "Client setup manual — server-side keys + CONNECT"
  echo
  echo "Both modes can coexist:"
  echo "  - Local-key CLIs use CONNECT (step 1 + Cursor login; grok with XAI_API_KEY; OpenCode /connect)."
  echo "  - grok -m gateway-grok and OpenCode provider.openrouter.options (GATEWAY_API_KEY) use server keys."
  echo
  echo "1) Shell"
  echo "   Paste into ~/.zshrc or ~/.bashrc, then open a new shell (or source the file)."
  echo
  echo "   NODE_USE_ENV_PROXY is for Cursor CONNECT. NO_PROXY must include the EIP"
  echo "   (${eip}) so http://${eip}:443/... is not sent through CONNECT."
  echo "   Gateway URLs MUST include :443 for the EIP HTTP path (cleartext HTTP on the mux port still works)."
  echo "   http://${eip}/xai/... (port 80) times out — security group opens 443 only. DNS-01 does not open 80."
  if [[ -n "$domain" && "$domain" != "null" ]]; then
    echo "   HTTPS is also on 443 with a Let's Encrypt public CA cert for ${domain}."
    echo "   No custom CA file. curl/Grok/OpenCode use the system trust store."
    echo "     curl --noproxy '*' https://${domain}/xai/v1/models"
    echo "   Commented HTTPS-by-IP (self-signed) remains a fallback; that path still needs ./proxy.sh ca."
    echo "   Zscaler (or similar) SSL inspection can still replace the issuer; apps that do not"
    echo "   trust the interceptor CA will see an untrusted issuer even though Let's Encrypt is public."
  else
    echo "   HTTPS is also on 443 (self-signed; not Let's Encrypt). Save the cert:"
    echo "     ./proxy.sh ca                 # writes ./gateway-tls-cert.pem"
    echo "     curl --cacert gateway-tls-cert.pem https://${eip}:443/..."
    echo "     NODE_EXTRA_CA_CERTS=./gateway-tls-cert.pem"
    echo "     SSL_CERT_FILE=./gateway-tls-cert.pem"
    echo "     GROK_EXTRA_CA_BUNDLE=./gateway-tls-cert.pem"
    echo "   Grok/OpenCode/Node fail TLS verify without that file."
    echo "   Zscaler (or similar) can still MITM HTTPS if the OS trusts the interceptor CA."
  fi
  echo
  printf '%s\n' "$exports"
  echo
  echo "2) Grok Build"
  if [[ -n "$xai_url" && "$xai_url" != "null" ]]; then
    echo "   Exact file: ~/.grok/config.toml  (or \$GROK_HOME/config.toml)"
    echo
    echo "   APPEND this block. Do not wipe existing [model.*] entries."
    echo
    echo "   Do NOT set GROK_CLI_CHAT_PROXY_BASE_URL."
    echo "   Do NOT put the real xAI key in this block."
    echo "   Real XAI_API_KEY is only for CONNECT / client-keyed usage."
    echo
    echo "   --- append to ~/.grok/config.toml ---"
    echo "[model.gateway-grok]"
    echo 'model = "grok-4.6"'
    echo "base_url = \"${xai_url}\""
    if [[ -n "$domain" && "$domain" != "null" && -n "$xai_https" && "$xai_https" != "null" ]]; then
      echo "# HTTPS (Let's Encrypt public CA; no custom CA file):"
      echo "# base_url = \"${xai_https}\""
      echo "# Fallback HTTPS by IP (self-signed; trust cert from ./proxy.sh ca):"
      echo "# base_url = \"https://${eip}:443/xai/v1\""
    else
      echo "# To connect over HTTPS instead (trust cert from ./proxy.sh ca):"
      echo "# base_url = \"https://${eip}:443/xai/v1\""
    fi
    echo 'api_backend = "chat_completions"'
    echo 'env_key = "GATEWAY_API_KEY"'
    echo 'name = "Grok via proxy gateway"'
    echo "   ---"
    echo
    echo "   Then:"
    echo "     grok -m gateway-grok"
  else
    echo "   xAI path disabled (no xai_api_key). Skip this file."
  fi
  echo
  echo "3) OpenCode"
  if [[ -n "$or_url" && "$or_url" != "null" ]]; then
    echo "   Exact file: ~/.config/opencode/opencode.json"
    echo
    echo "   Merge this into the existing file. Do not replace the whole JSON."
    echo "   This keeps OpenRouter's full model catalog; requests go to the box;"
    echo "   HAProxy injects the real OpenRouter key."
    echo "   Do not /connect with the real sk-or key for this path."
    echo
    echo "   --- merge into ~/.config/opencode/opencode.json ---"
    echo "{"
    echo "  \"provider\": {"
    echo "    \"openrouter\": {"
    echo "      \"options\": {"
    echo "        \"baseURL\": \"${or_url}\","
        if [[ -n "$domain" && "$domain" != "null" && -n "$or_https" && "$or_https" != "null" ]]; then
          echo "        // HTTPS (Let's Encrypt public CA; no custom CA file):"
          echo "        // \"baseURL\": \"${or_https}\","
          echo "        // Fallback HTTPS by IP (self-signed; trust ./proxy.sh ca):"
          echo "        // \"baseURL\": \"https://${eip}:443/openrouter/api/v1\","
        else
          echo "        // To connect over HTTPS instead (trust cert from ./proxy.sh ca):"
          echo "        // \"baseURL\": \"https://${eip}:443/openrouter/api/v1\","
        fi
    echo "        \"apiKey\": \"{env:GATEWAY_API_KEY}\""
    echo "      }"
    echo "    }"
    echo "  }"
    echo "}"
    echo "   ---"
    echo
    if [[ -n "$domain" && "$domain" != "null" ]]; then
      echo "   HTTPS to ${domain} needs no custom CA. HTTPS by IP still uses ./proxy.sh ca."
    else
      echo "   For HTTPS, trust the cert from ./proxy.sh ca (NODE_EXTRA_CA_CERTS / SSL_CERT_FILE)."
    fi
  else
    echo "   OpenRouter path disabled (no openrouter_api_key). Skip this file."
  fi
  echo
  echo "4) Cursor CLI"
  echo "   Cannot use the gateway. CONNECT exports only (step 1) + local login."
  echo "   No toml/json change."
  echo
  echo "5) Both modes can coexist"
  echo "   Local-key CLIs use CONNECT."
  echo "   grok -m gateway-grok and OpenCode provider.openrouter.options use server keys."
  echo
  echo "6) SSH tunnel (password auth)"
  local ssh_en ssh_cmd user
  ssh_en="$(out_get ssh_enabled)"
  ssh_cmd="$(ssh_tunnel_cmd "$eip")" || ssh_cmd=""
  user="starman"
  if [[ "$ssh_cmd" =~ ([A-Za-z0-9._-]+)@ ]]; then
    user="${BASH_REMATCH[1]}"
  fi
  if [[ "$ssh_en" == "false" ]]; then
    echo "   Disabled (ssh_enabled=false). Direct EIP :443 path still works. SSM: ./proxy.sh ssm"
    return 0
  fi
  echo "   User: ${user}  (same as CONNECT). Password: the CONNECT password (step 1)."
  echo "   No SSH key. ssh prompts; no sshpass required. SSM still works: ./proxy.sh ssm"
  echo
  echo "   ./proxy.sh tunnel start|status|stop"
  echo "   start is equivalent to:"
  if [[ -n "$ssh_cmd" ]]; then
    echo "     ${ssh_cmd}"
  else
    echo "     ssh -N -f -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o PreferredAuthentications=password -o PubkeyAuthentication=no -L 1443:127.0.0.1:443 ${user}@${eip}"
  fi
  echo "   -N/-f prints nothing after the password; silence means the tunnel is up. Ctrl-C does not apply once -f daemonizes (./proxy.sh tunnel stop)."
  echo
  echo "   Then use loopback :1443. Direct EIP path keeps :443 (http://${eip}:443/...)."
  echo "   NO_PROXY must include 127.0.0.1,localhost (step 1 already does)."
  if [[ -n "$domain" && "$domain" != "null" ]]; then
    echo "   Let's Encrypt SAN does not include 127.0.0.1. Use HTTP on the tunnel:"
    echo "     http://127.0.0.1:1443/..."
    echo "   https://127.0.0.1:1443/... will fail hostname verification against the public CA cert."
  else
    echo "   HTTPS tunnel URLs work too (cert SAN includes 127.0.0.1):"
    echo "     https://127.0.0.1:1443/...   with --cacert / NODE_EXTRA_CA_CERTS from ./proxy.sh ca"
  fi
  echo
  if [[ -n "$xai_url" && "$xai_url" != "null" ]]; then
    echo "     Grok     base_url  http://127.0.0.1:1443/xai/v1"
    if [[ -z "$domain" || "$domain" == "null" ]]; then
      echo "               or       https://127.0.0.1:1443/xai/v1"
    fi
  fi
  if [[ -n "$or_url" && "$or_url" != "null" ]]; then
    echo "     OpenCode baseURL   http://127.0.0.1:1443/openrouter/api/v1"
    if [[ -z "$domain" || "$domain" == "null" ]]; then
      echo "               or       https://127.0.0.1:1443/openrouter/api/v1"
    fi
  fi
  echo "     CONNECT  HTTP_PROXY / HTTPS_PROXY  http://${user}:PASS@127.0.0.1:1443"
  echo "              Cursor still uses HTTP CONNECT. Clients that support an HTTPS proxy:"
  echo "              https://${user}:PASS@${eip}:443  (trust the cert; PASS is CONNECT, not GATEWAY_API_KEY)"
  echo "              (PASS is the CONNECT password from step 1; do not reuse GATEWAY_API_KEY)"
}

cmd_smoke_gateway() {
  has_outputs || die "no terraform outputs yet — run ./proxy.sh setup first"
  local gw eip token xai ortr url code rc domain
  gw="$(out_get gateway_enabled)"
  [[ "$gw" == "true" ]] || die "gateway is off; set a vendor key and ./proxy.sh setup"
  eip="$(out_get eip_public_ip)"
  token="$(tf output -raw gateway_token)"
  xai="$(out_get gateway_xai_enabled)"
  ortr="$(out_get gateway_openrouter_enabled)"
  domain="$(out_get domain_name)"
  smoke_one() {
    local path="$1"
    url="$(mux_http_url "http://${eip}${path}")"
    set +e
    code="$(curl -sS --noproxy '*' --connect-timeout 15 --max-time 30 \
      -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer ${token}" \
      "$url" 2>/dev/null)"
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
      die "smoke-gateway failed (${path}: connection refused or timeout)"
    fi
    if [[ "$code" == "401" ]]; then
      die "smoke-gateway failed (${path}: 401)"
    fi
    if [[ "$code" == "403" || "$code" == "404" ]]; then
      die "smoke-gateway failed (${path}: ${code})"
    fi
    if [[ "$code" =~ ^2 ]]; then
      ok "gateway ${path} ${code}"
      return 0
    fi
    die "smoke-gateway failed (${path}: HTTP ${code})"
  }
  local any=0
  if [[ "$xai" == "true" ]]; then
    smoke_one "/xai/v1/models"
    any=1
  fi
  if [[ "$ortr" == "true" ]]; then
    smoke_one "/openrouter/api/v1/models"
    any=1
  fi
  [[ "$any" -eq 1 ]] || die "gateway is on but no vendor paths are enabled"

  local cert curl_ca=()
  cert="$(mktemp)"
  trap 'rm -f "$cert"' RETURN
  if [[ -n "$domain" && "$domain" != "null" ]]; then
    rm -f "$cert"
    cert=""
    trap - RETURN
  else
    if ! tf output -raw gateway_tls_cert_pem >"$cert" 2>/dev/null; then
      info "https smoke skipped (no gateway_tls_cert_pem)"
      return 0
    fi
    if ! grep -q "BEGIN CERTIFICATE" "$cert"; then
      info "https smoke skipped (empty cert output)"
      return 0
    fi
    curl_ca=(--cacert "$cert")
  fi
  smoke_one_https() {
    local path="$1"
    if [[ -n "$domain" && "$domain" != "null" ]]; then
      url="https://${domain}${path}"
    else
      url="https://${eip}:443${path}"
    fi
    set +e
    code="$(curl -sS --noproxy '*' "${curl_ca[@]}" --connect-timeout 15 --max-time 30       -o /dev/null -w '%{http_code}'       -H "Authorization: Bearer ${token}"       "$url" 2>/dev/null)"
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
      die "smoke-gateway https failed (${path}: connection refused, timeout, or TLS error)"
    fi
    if [[ "$code" == "401" ]]; then
      die "smoke-gateway https failed (${path}: 401)"
    fi
    if [[ "$code" == "403" || "$code" == "404" ]]; then
      die "smoke-gateway https failed (${path}: ${code})"
    fi
    if [[ "$code" =~ ^2 ]]; then
      ok "gateway https ${path} ${code}"
      return 0
    fi
    die "smoke-gateway https failed (${path}: HTTP ${code})"
  }
  if [[ "$xai" == "true" ]]; then
    smoke_one_https "/xai/v1/models"
  fi
  if [[ "$ortr" == "true" ]]; then
    smoke_one_https "/openrouter/api/v1/models"
  fi
}

cmd_ssm() {
  has_outputs || die "no terraform outputs yet — run ./proxy.sh setup first"
  local cmd
  cmd="$(tf output -raw ssm_start_session_command)"
  info "$cmd"
  local -a args
  # shellcheck disable=SC2206
  args=($cmd)
  exec "${args[@]}"
}

TUNNEL_PORT=1443
TUNNEL_SPEC='1443:127.0.0.1:443'

# Unique numeric PIDs, one per line. Drops this script's pid.
tunnel_uniq_pids() {
  awk -v self="$$" 'NF && $1 ~ /^[0-9]+$/ && $1 != self { if (!seen[$1]++) print $1 }'
}

# PIDs LISTEN on local 1443. Prefer lsof (macOS); ss/fuser as Linux-ish fallbacks.
tunnel_listen_pids() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$TUNNEL_PORT" -sTCP:LISTEN -t 2>/dev/null || true
  elif command -v ss >/dev/null 2>&1; then
    ss -lptn "sport = :${TUNNEL_PORT}" 2>/dev/null | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' || true
  elif command -v fuser >/dev/null 2>&1; then
    fuser "${TUNNEL_PORT}/tcp" 2>/dev/null | tr -cs '0-9' '\n' || true
  fi
}

tunnel_pid_comm() {
  ps -p "$1" -o comm= 2>/dev/null | awk '{print $1}' | sed 's|.*/||' || true
}

# ssh clients with -L 1443:127.0.0.1:443 (not github/unrelated ssh).
tunnel_forward_pids() {
  local pid comm
  if command -v pgrep >/dev/null 2>&1; then
    for pid in $(pgrep -f "$TUNNEL_SPEC" 2>/dev/null || true); do
      comm="$(tunnel_pid_comm "$pid")"
      if [[ "$comm" == "ssh" ]]; then
        printf '%s\n' "$pid"
      fi
    done
  else
    for pid in $(ps -axo pid=,command= 2>/dev/null | awk -v spec="$TUNNEL_SPEC" 'index($0, spec) { print $1 }'); do
      comm="$(tunnel_pid_comm "$pid")"
      if [[ "$comm" == "ssh" ]]; then
        printf '%s\n' "$pid"
      fi
    done
  fi
}

# LISTEN on 1443 whose process is the local ssh client (the tunnel).
tunnel_listen_ssh_pids() {
  local pid comm
  for pid in $(tunnel_listen_pids | tunnel_uniq_pids); do
    comm="$(tunnel_pid_comm "$pid")"
    if [[ "$comm" == "ssh" ]]; then
      printf '%s\n' "$pid"
    fi
  done
}

tunnel_kill_targets() {
  {
    tunnel_forward_pids
    tunnel_listen_ssh_pids
  } | tunnel_uniq_pids
}

tunnel_listen_addrs() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$TUNNEL_PORT" -sTCP:LISTEN -F n 2>/dev/null | sed -n 's/^n//p' | sort -u
  elif command -v ss >/dev/null 2>&1; then
    ss -lntn "sport = :${TUNNEL_PORT}" 2>/dev/null | awk 'NR>1 {print $4}' | sort -u
  fi
}

tunnel_pids_oneline() {
  awk 'NF { printf "%s%s", (n++ ? " " : ""), $1 } END { if (n) print "" }'
}

cmd_tunnel_usage() {
  cat <<EOF
${BOLD}./proxy.sh tunnel <command>${RESET}

  ${BOLD}start${RESET}    Print and exec ssh -N -f -L 1443:127.0.0.1:443 (CONNECT password). No-op if 1443 is already up
  ${BOLD}status${RESET}   Report whether 127.0.0.1:1443 is forwarded (exit 0 if up, 1 if down)
  ${BOLD}stop${RESET}     Kill the local 1443 tunnel ssh only. Exit 0 if already down
EOF
}

cmd_tunnel_start() {
  local listen_pids pids_line cmd enabled
  listen_pids="$(tunnel_listen_pids | tunnel_uniq_pids)"
  if [[ -n "$listen_pids" ]]; then
    pids_line="$(printf '%s\n' "$listen_pids" | tunnel_pids_oneline)"
    info "tunnel already up (pid ${pids_line})"
    return 0
  fi
  has_outputs || die "no terraform outputs yet — run ./proxy.sh setup first"
  enabled="$(out_get ssh_enabled)"
  if [[ "$enabled" == "false" ]]; then
    die "ssh_enabled is false; set ssh_enabled = true and ./proxy.sh setup"
  fi
  cmd="$(ssh_tunnel_cmd)" || die "eip_public_ip missing"
  info "$cmd"
  info "-N/-f prints nothing after the password; silence means the tunnel is up. Ctrl-C does not apply once -f daemonizes (./proxy.sh tunnel stop)."
  local -a args
  # shellcheck disable=SC2206
  args=($cmd)
  exec "${args[@]}"
}

cmd_tunnel_status() {
  local listen_pids forward_pids pids_line addrs addrs_line
  listen_pids="$(tunnel_listen_pids | tunnel_uniq_pids)"
  forward_pids="$(tunnel_forward_pids | tunnel_uniq_pids)"
  if [[ -z "$listen_pids" ]]; then
    info "tunnel    down"
    if [[ -n "$forward_pids" ]]; then
      pids_line="$(printf '%s\n' "$forward_pids" | tunnel_pids_oneline)"
      info "pid       ${pids_line} (ssh matching ${TUNNEL_SPEC}, not listening)"
    fi
    return 1
  fi
  pids_line="$(printf '%s\n' "$listen_pids" | tunnel_pids_oneline)"
  addrs="$(tunnel_listen_addrs)"
  addrs_line="$(printf '%s\n' "$addrs" | awk 'NF { printf "%s%s", (n++ ? " " : ""), $1 } END { if (n) print "" }')"
  info "tunnel    up"
  info "pid       ${pids_line}"
  if [[ -n "$addrs_line" ]]; then
    info "listen    ${addrs_line}"
  fi
  return 0
}

cmd_tunnel_stop() {
  local targets pid remaining i leftover leftover_line comm
  targets="$(tunnel_kill_targets)"
  if [[ -z "$targets" ]]; then
    leftover="$(tunnel_listen_pids | tunnel_uniq_pids)"
    if [[ -n "$leftover" ]]; then
      leftover_line="$(printf '%s\n' "$leftover" | tunnel_pids_oneline)"
      die "1443 is in use by pid ${leftover_line} (not the 1443 SSH tunnel)"
    fi
    info "tunnel already down"
    return 0
  fi
  for pid in $targets; do
    kill "$pid" 2>/dev/null || true
  done
  i=0
  while [[ $i -lt 20 ]]; do
    remaining="$(tunnel_kill_targets)"
    if [[ -z "$remaining" ]]; then
      break
    fi
    sleep 0.1
    i=$((i + 1))
  done
  remaining="$(tunnel_kill_targets)"
  if [[ -n "$remaining" ]]; then
    for pid in $remaining; do
      kill -9 "$pid" 2>/dev/null || true
    done
    sleep 0.1
  fi
  leftover="$(tunnel_listen_pids | tunnel_uniq_pids)"
  if [[ -n "$leftover" ]]; then
    leftover_line="$(printf '%s\n' "$leftover" | tunnel_pids_oneline)"
    comm="$(tunnel_pid_comm "$(printf '%s\n' "$leftover" | head -n1)")"
    if [[ "$comm" == "ssh" ]]; then
      die "tunnel still listening on 1443 (pid ${leftover_line})"
    fi
    die "1443 still in use by pid ${leftover_line} (not the 1443 SSH tunnel)"
  fi
  ok "tunnel stopped (1443 is free)"
}

cmd_tunnel() {
  local sub="${1:-}"
  case "$sub" in
    ""|help|-h|--help) cmd_tunnel_usage ;;
    start) cmd_tunnel_start ;;
    status) cmd_tunnel_status ;;
    stop) cmd_tunnel_stop ;;
    *) die "unknown tunnel command: $sub (try ./proxy.sh tunnel)" ;;
  esac
}

main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    help|-h|--help) cmd_help ;;
    destroy) cmd_destroy ;;
    setup|apply|up) cmd_setup ;;
    zshrc|env|repair) cmd_zshrc ;;
    client|snippet|exports) cmd_client ;;
    instructions) cmd_client_instructions ;;
    ca|cert|cacert) cmd_ca "$@" ;;
    status) cmd_status ;;
    smoke) cmd_smoke ;;
    smoke-gateway) cmd_smoke_gateway ;;
    ssm) cmd_ssm ;;
    tunnel) cmd_tunnel "$@" ;;
    *) die "unknown command: $cmd (try ./proxy.sh help)" ;;
  esac
}

main "$@"
