#!/bin/bash
# Idempotent password SSH for the CONNECT proxy user. Safe on an already-configured box.
# Invoked by the SSM association (not EC2 user-data). Do not set -x: never print the password.
set -euo pipefail

PROXY_USER='{{ proxyUser }}'
SSM_PARAMETER_NAME='{{ ssmPasswordParameter }}'

log() { echo "configure-ssh: $*"; }

log "start $(date -u +%FT%TZ) user=${PROXY_USER}"

retry() {
  local attempts="$1" delay="$2"
  shift 2
  local n=1
  until "$@"; do
    if [ "$n" -ge "$attempts" ]; then
      echo "giving up after ${n} attempts: $*"
      return 1
    fi
    echo "retry ${n}/${attempts} in ${delay}s: $*"
    n=$((n + 1))
    sleep "$delay"
  done
}

imds_token() {
  curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"
}

TOKEN="$(retry 15 2 imds_token)"
REGION="$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)"
export AWS_DEFAULT_REGION="$REGION"

if ! command -v python3 >/dev/null 2>&1; then
  retry 10 5 dnf install -y python3
fi
if ! command -v aws >/dev/null 2>&1; then
  retry 10 5 dnf install -y aws-cli
fi
if ! command -v sshd >/dev/null 2>&1; then
  retry 10 5 dnf install -y openssh-server
fi

systemctl enable sshd
systemctl start sshd

if ! getent passwd "$PROXY_USER" >/dev/null; then
  useradd -m -s /bin/bash "$PROXY_USER"
  log "created user ${PROXY_USER}"
else
  usermod -s /bin/bash "$PROXY_USER" || true
  HOME_DIR="$(getent passwd "$PROXY_USER" | cut -d: -f6)"
  if [ -n "$HOME_DIR" ] && [ ! -d "$HOME_DIR" ]; then
    mkdir -p "$HOME_DIR"
    chown "${PROXY_USER}:${PROXY_USER}" "$HOME_DIR"
  fi
  log "user ${PROXY_USER} already exists"
fi

# Fetch CONNECT password from SSM and set it; write sshd drop-in. Password never printed.
python3 - "$PROXY_USER" "$SSM_PARAMETER_NAME" <<'PY'
import pathlib
import subprocess
import sys

user, param = sys.argv[1], sys.argv[2]

r = subprocess.run(
    [
        "aws",
        "ssm",
        "get-parameter",
        "--name",
        param,
        "--with-decryption",
        "--query",
        "Parameter.Value",
        "--output",
        "text",
    ],
    check=True,
    capture_output=True,
    text=True,
)
password = r.stdout.rstrip("\n\r")
if not password or password == "None":
    raise SystemExit("SSM password parameter was empty")

cp = subprocess.run(
    ["chpasswd"],
    input=f"{user}:{password}\n",
    capture_output=True,
    text=True,
)
if cp.returncode != 0:
    raise SystemExit("chpasswd failed")

dropin = pathlib.Path("/etc/ssh/sshd_config.d/99-password.conf")
dropin.parent.mkdir(parents=True, exist_ok=True)
# Match live /etc/ssh/sshd_config.d/99-password.conf
dropin.write_text(
    "PasswordAuthentication yes\n"
    "KbdInteractiveAuthentication yes\n"
    "ChallengeResponseAuthentication yes\n"
    "PermitRootLogin no\n"
    "AllowTcpForwarding yes\n"
    f"AllowUsers {user}\n"
)
dropin.chmod(0o644)
PY

sshd -t
if systemctl is-active --quiet sshd; then
  systemctl reload sshd
else
  systemctl start sshd
fi

log "done $(date -u +%FT%TZ)"
