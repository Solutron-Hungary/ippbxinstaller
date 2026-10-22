#!/usr/bin/env bash
# Solutron installer — takes over a fresh Debian 13 (amd64) host.
# https://github.com/Solutron-Hungary/ippbxinstaller
#
#   curl -fsSL https://raw.githubusercontent.com/Solutron-Hungary/ippbxinstaller/main/install.sh -o install.sh
#   bash install.sh            # as root
#
# Non-interactive: GHCR_USER=... GHCR_TOKEN=... bash install.sh
# Interim (lab) mode: images are pulled with a GHCR token until licence keys land.
# Overrides: SOLUTRON_TAG (default 0.5.1, "main" for the latest dev build), ASTERISK_TAG (default 24.0.0-rc2),
#            COSIGN_VERSION (default latest), KEEP_GHCR_LOGIN=1 (keep docker login),
#            POSTGRES_IMAGE (default postgres:17-bookworm; pinned by digest on first install)
#
# Idempotent: running it again re-verifies, re-pulls and restarts the stack.
set -euo pipefail

# ---------------------------------------------------------------------------
REGISTRY=ghcr.io
IMAGE_BASE=ghcr.io/solutron-hungary/ippbxsystem
INSTALLER_VERSION=0.6.1
SOLUTRON_TAG=${SOLUTRON_TAG:-0.5.1}
ASTERISK_TAG=${ASTERISK_TAG:-24.0.0-rc2}
POSTGRES_TAG=postgres:17-bookworm
COSIGN_VERSION=${COSIGN_VERSION:-latest}
SIGNER_ID='^https://github.com/Solutron-Hungary/ippbxsystem/\.github/workflows/_image\.yml@refs/(heads/main|tags/v.*)$'
OIDC_ISSUER=https://token.actions.githubusercontent.com
# Docker's apt signing key, as published in Docker's install docs.
DOCKER_GPG_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88

SRV=/srv/solutron
DATA=/var/lib/solutron
AST_UID=2000
LOG=/var/log/solutron-install.log
# ---------------------------------------------------------------------------

step() { printf '\n==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
trap 'printf "\nERROR: install failed at line %s (see %s)\n" "$LINENO" "$LOG" >&2' ERR

[[ $EUID -eq 0 ]] || die "run as root"
touch "$LOG" && chmod 0600 "$LOG"
exec > >(tee -a "$LOG") 2>&1
echo "--- installer ${INSTALLER_VERSION}, solutron ${SOLUTRON_TAG}, asterisk ${ASTERISK_TAG}, $(date -Is) ---"

# --- 1. Preflight ----------------------------------------------------------
step "Preflight"
# shellcheck source=/dev/null
. /etc/os-release
[[ ${ID:-} == debian && ${VERSION_ID:-} == 13 ]] || die "Debian 13 required, found ${PRETTY_NAME:-unknown}"
[[ $(uname -m) == x86_64 ]] || die "amd64 required, found $(uname -m)"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg jq >/dev/null

code=$(curl -s -o /dev/null -w '%{http_code}' "https://${REGISTRY}/v2/" || true)
[[ $code == 401 || $code == 200 ]] || die "cannot reach ${REGISTRY} (HTTP ${code:-none})"
echo "ok: Debian 13 amd64, ${REGISTRY} reachable"

# --- 2. Docker (official repo, held) ----------------------------------------
step "Docker"
if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
  echo "already installed: $(docker --version)"
else
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  fpr=$(gpg --show-keys --with-colons /etc/apt/keyrings/docker.asc | awk -F: '/^fpr/ {print $10; exit}')
  [[ $fpr == "$DOCKER_GPG_FPR" ]] || die "Docker apt key fingerprint mismatch: $fpr"
  chmod a+r /etc/apt/keyrings/docker.asc

  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null
  # Docker upgrades go through the Solutron update wizard, not unattended apt.
  apt-mark hold docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null
fi

# live-restore keeps calls up while dockerd restarts; local log driver rotates.
mkdir -p /etc/docker
desired='{"live-restore":true,"log-driver":"local","log-opts":{"max-size":"20m","max-file":"5"}}'
if [[ ! -f /etc/docker/daemon.json ]] || [[ $(jq -cS . /etc/docker/daemon.json) != $(jq -cS . <<<"$desired") ]]; then
  jq . <<<"$desired" > /etc/docker/daemon.json
  systemctl restart docker
fi
systemctl enable --now docker >/dev/null
echo "ok: $(docker --version), $(docker compose version --short)"

# --- 3. cosign --------------------------------------------------------------
step "cosign"
if [[ $COSIGN_VERSION == latest ]]; then
  cosign_url=https://github.com/sigstore/cosign/releases/latest/download
else
  cosign_url=https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}
fi
tmp=$(mktemp -d)
curl -fsSL -o "${tmp}/cosign-linux-amd64" "${cosign_url}/cosign-linux-amd64"
curl -fsSL -o "${tmp}/cosign_checksums.txt" "${cosign_url}/cosign_checksums.txt"
(cd "$tmp" && grep ' cosign-linux-amd64$' cosign_checksums.txt | sha256sum -c -) \
  || die "cosign checksum mismatch"
install -m 0755 "${tmp}/cosign-linux-amd64" /usr/local/bin/cosign
rm -rf "$tmp"
echo "ok: $(cosign version 2>&1 | awk '/GitVersion/ {print $2}')"

# --- 4. GHCR login ----------------------------------------------------------
step "GHCR login"
if [[ -z ${GHCR_USER:-} ]]; then read -rp "GitHub username: " GHCR_USER </dev/tty; fi
if [[ -z ${GHCR_TOKEN:-} ]]; then read -rsp "GHCR token (read:packages): " GHCR_TOKEN </dev/tty; echo; fi
docker login "$REGISTRY" -u "$GHCR_USER" --password-stdin <<<"$GHCR_TOKEN" >/dev/null
unset GHCR_TOKEN
echo "ok: logged in as ${GHCR_USER}"

# --- 5. Verify signatures, then pull by digest -------------------------------
step "Verify and pull images"
verify_and_pull() {
  local ref=$1 out digest errf
  errf=$(mktemp)
  if ! out=$(cosign verify "$ref" \
               --certificate-identity-regexp "$SIGNER_ID" \
               --certificate-oidc-issuer "$OIDC_ISSUER" 2>"$errf"); then
    cat "$errf" >&2
    if grep -qiE "MANIFEST_UNKNOWN|tag not found" "$errf"; then
      rm -f "$errf"
      die "${ref} does not exist in the registry (version not released yet, or a typo in the tag)"
    fi
    rm -f "$errf"
    die "signature verification FAILED for ${ref}: not signed by the Solutron release pipeline"
  fi
  rm -f "$errf"
  digest=$(jq -r '.[0].critical.image."docker-manifest-digest"' <<<"$out")
  [[ $digest == sha256:* ]] || die "no digest in cosign output for ${ref}"
  docker pull -q "${ref%:*}@${digest}" >/dev/null
  echo "${ref%:*}@${digest}"
}
ASTERISK_IMAGE=$(verify_and_pull "${IMAGE_BASE}/asterisk:${ASTERISK_TAG}")
SOLUTRON_IMAGE=$(verify_and_pull "${IMAGE_BASE}/solutron:${SOLUTRON_TAG}")
echo "ok: ${ASTERISK_IMAGE}"
echo "ok: ${SOLUTRON_IMAGE}"

# PostgreSQL for CDR and the queue log: the official image, not signed by us.
# The first install pins the digest it pulled; later runs reuse that exact
# image until POSTGRES_IMAGE asks for another one.
mkdir -p "${SRV}/postgres"
pin_file="${SRV}/postgres/image"
if [[ -n ${POSTGRES_IMAGE:-} ]]; then
  pg_ref=$POSTGRES_IMAGE
elif [[ -s $pin_file ]]; then
  pg_ref=$(cat "$pin_file")
else
  pg_ref=$POSTGRES_TAG
fi
docker pull -q "$pg_ref" >/dev/null || die "cannot pull ${pg_ref}"
POSTGRES_IMAGE=$(docker image inspect -f '{{index .RepoDigests 0}}' "$pg_ref")
[[ $POSTGRES_IMAGE == *@sha256:* ]] || die "no digest for ${pg_ref}"
echo "$POSTGRES_IMAGE" > "$pin_file"
echo "ok: ${POSTGRES_IMAGE}"


if [[ ${KEEP_GHCR_LOGIN:-0} != 1 ]]; then
  docker logout "$REGISTRY" >/dev/null   # credentials sit unencrypted in /root/.docker otherwise
fi

# --- 6. Filesystem layout ---------------------------------------------------
step "Filesystem"
mkdir -p "${SRV}/asterisk/etc" \
         "${DATA}/asterisk/astdb" "${DATA}/asterisk/spool/monitor/solutron" "${DATA}/asterisk/log" \
         "${DATA}/asterisk/sounds/moh" "${DATA}/postgres"

# Seed the Asterisk config from the image baseline, only on first install:
# from here on Solutron owns this directory.
fresh=0
if [[ -z $(ls -A "${SRV}/asterisk/etc") ]]; then
  fresh=1
  docker run --rm --entrypoint tar "$ASTERISK_IMAGE" -C /etc/asterisk -cf - . \
    | tar -xf - -C "${SRV}/asterisk/etc"
  # Keep astdb out of /var/lib/asterisk so sounds keep coming from the image.
  sed -i 's|^astdbdir *=>.*|astdbdir => /var/lib/asterisk/astdb|' "${SRV}/asterisk/etc/asterisk.conf"
  echo "seeded ${SRV}/asterisk/etc from image"
fi
chown -R root:"$AST_UID" "${SRV}/asterisk/etc"
find "${SRV}/asterisk/etc" -type d -exec chmod 0750 {} +
find "${SRV}/asterisk/etc" -type f -exec chmod 0640 {} +
chown -R "$AST_UID":"$AST_UID" "${DATA}/asterisk"
chmod 0750 "${DATA}/asterisk/sounds" "${DATA}/asterisk/sounds/moh"

# Model (YAML, secrets.yaml inside) and revision snapshots: Solutron only.
install -d -m 0700 -o root -g root "${SRV}/model" "${SRV}/revisions" "${SRV}/state"

# Database password: generated once. Solutron copies it into the model
# (secrets.yaml) at start; PostgreSQL gets it from a root-only env file.
if [[ ! -s ${SRV}/state/db-password ]]; then
  (umask 077; head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32 > "${SRV}/state/db-password")
fi
(umask 077; printf 'POSTGRES_USER=solutron\nPOSTGRES_DB=solutron\nPOSTGRES_PASSWORD=%s\n' "$(cat "${SRV}/state/db-password")" > "${SRV}/postgres/env")

# Schema for Asterisk's cdr_pgsql and the realtime queue log. Runs only when
# the database directory is empty (first start).
cat > "${SRV}/postgres/init.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS cdr (
  calldate    timestamptz NOT NULL DEFAULT now(),
  clid        text NOT NULL DEFAULT '',
  src         text NOT NULL DEFAULT '',
  dst         text NOT NULL DEFAULT '',
  dcontext    text NOT NULL DEFAULT '',
  channel     text NOT NULL DEFAULT '',
  dstchannel  text NOT NULL DEFAULT '',
  lastapp     text NOT NULL DEFAULT '',
  lastdata    text NOT NULL DEFAULT '',
  duration    integer NOT NULL DEFAULT 0,
  billsec     integer NOT NULL DEFAULT 0,
  disposition text NOT NULL DEFAULT '',
  amaflags    integer NOT NULL DEFAULT 0,
  accountcode text NOT NULL DEFAULT '',
  uniqueid    text NOT NULL DEFAULT '',
  userfield   text NOT NULL DEFAULT '',
  peeraccount text NOT NULL DEFAULT '',
  linkedid    text NOT NULL DEFAULT '',
  sequence    integer NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS cdr_calldate ON cdr (calldate);
CREATE INDEX IF NOT EXISTS cdr_uniqueid ON cdr (uniqueid);
CREATE INDEX IF NOT EXISTS cdr_accountcode ON cdr (accountcode);
CREATE TABLE IF NOT EXISTS queue_log (
  id        bigserial PRIMARY KEY,
  time      timestamptz NOT NULL DEFAULT now(),
  callid    text NOT NULL DEFAULT '',
  queuename text NOT NULL DEFAULT '',
  agent     text NOT NULL DEFAULT '',
  event     text NOT NULL DEFAULT '',
  data      text NOT NULL DEFAULT '',
  data1     text NOT NULL DEFAULT '',
  data2     text NOT NULL DEFAULT '',
  data3     text NOT NULL DEFAULT '',
  data4     text NOT NULL DEFAULT '',
  data5     text NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS queue_log_time ON queue_log (time);
CREATE INDEX IF NOT EXISTS queue_log_callid ON queue_log (callid);
SQL
chmod 0644 "${SRV}/postgres/init.sql"

# --- 7. Compose -------------------------------------------------------------
step "Compose"
cat > "${SRV}/compose.yml" <<EOF
# Generated by install.sh $(date -Is). Images are pinned by verified digest.
name: solutron
services:
  asterisk:
    image: ${ASTERISK_IMAGE}
    container_name: solutron-asterisk
    network_mode: host
    restart: unless-stopped
    volumes:
      - ${SRV}/asterisk/etc:/etc/asterisk:ro
      - ${DATA}/asterisk/astdb:/var/lib/asterisk/astdb
      - ${DATA}/asterisk/spool:/var/spool/asterisk
      - ${DATA}/asterisk/log:/var/log/asterisk
      - ${DATA}/asterisk/sounds:/var/lib/asterisk/sounds/solutron
    depends_on: [postgres]

  postgres:
    image: ${POSTGRES_IMAGE}
    container_name: solutron-postgres
    restart: unless-stopped
    env_file: ${SRV}/postgres/env
    # Only the host itself: Asterisk (host network) and Solutron reach it here.
    ports:
      - "127.0.0.1:5432:5432"
    volumes:
      - ${DATA}/postgres:/var/lib/postgresql/data
      - ${SRV}/postgres/init.sql:/docker-entrypoint-initdb.d/10-solutron.sql:ro
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "solutron", "-d", "solutron"]
      interval: 10s
      timeout: 5s
      retries: 10

  solutron:
    image: ${SOLUTRON_IMAGE}
    container_name: solutron-app
    restart: unless-stopped
    ports:
      - "8080:8080"
    # Solutron manages the host: it renders into ${SRV}, starts lab containers
    # and reloads Asterisk through the Docker socket. The socket is root-
    # equivalent anyway, so it runs as root with only the capability to chown
    # the Asterisk config to the asterisk group.
    user: "0:0"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ${SRV}:${SRV}
      # Prompts and music (GUI uploads), recordings (retention).
      - ${DATA}/asterisk/sounds:${DATA}/asterisk/sounds
      - ${DATA}/asterisk/spool:${DATA}/asterisk/spool
    read_only: true
    cap_drop: [ALL]
    cap_add: [CHOWN]
    security_opt: ["no-new-privileges:true"]
EOF
docker compose -f "${SRV}/compose.yml" up -d --remove-orphans

# --- 8. Health --------------------------------------------------------------
step "Health check"
for i in $(seq 1 60); do
  status=$(docker inspect -f '{{.State.Health.Status}}' solutron-asterisk 2>/dev/null || echo starting)
  [[ $status == healthy ]] && break
  (( i == 60 )) && { docker logs --tail 50 solutron-asterisk; die "asterisk not healthy after 120s ($status)"; }
  sleep 2
done
for i in $(seq 1 30); do
  pgs=$(docker inspect -f '{{.State.Health.Status}}' solutron-postgres 2>/dev/null || echo starting)
  [[ $pgs == healthy ]] && break
  (( i == 30 )) && { docker logs --tail 30 solutron-postgres; die "postgres not healthy after 60s ($pgs)"; }
  sleep 2
done
echo "ok: postgres healthy"
echo "ok: asterisk healthy ($(docker exec solutron-asterisk asterisk -rx 'core show version' | awk '{print $1, $2}'))"

health=$(curl -fsS http://127.0.0.1:8080/api/v1/health) || die "solutron API not answering"
echo "ok: solutron $(jq -r '.version.version' <<<"$health") ($(jq -r '.version.commit' <<<"$health" | cut -c1-12))"

ip=$(hostname -I | awk '{print $1}')
# Admin password for the GUI: generated once, never overwritten here. On a
# re-run the password already exists and the command prints nothing.
admin_pw=""
pw_state=failed
if admin_pw=$(docker exec solutron-app /usr/local/bin/solutron set-admin-password -if-missing); then
  if [[ -n $admin_pw ]]; then pw_state=new; else pw_state=kept; fi
fi
# The GUI greets the first visitor after a fresh install, once.
if (( fresh )); then
  echo "$ip" > "${SRV}/state/install-done"
fi
cat <<EOF

Solutron is up.
  GUI:      http://${ip}:8080/
  API:      http://${ip}:8080/api/v1/health
  Asterisk: docker exec -it solutron-asterisk asterisk -r
  Compose:  ${SRV}/compose.yml
  Log:      ${LOG}
EOF
reset_cmd="docker exec solutron-app /usr/local/bin/solutron set-admin-password"
case $pw_state in
  kept)
    printf '\n  GUI login: user "admin", password unchanged (set by an earlier install).\n  To set a new one: %s\n' "$reset_cmd"
    ;;
  failed)
    printf '\n  WARNING: could not check the GUI admin password. Set one with:\n    %s\n' "$reset_cmd"
    ;;
esac
if [[ $pw_state == new ]]; then
  # The password must not reach the install log: straight to the terminal,
  # or (non-interactive run) to a root-only file whose path is logged.
  msg="
  GUI login: user \"admin\", password: ${admin_pw}
  Save it now; it is not shown again. To set a new one:
    ${reset_cmd}"
  if { true > /dev/tty; } 2>/dev/null; then
    printf '%s\n' "$msg" > /dev/tty
  else
    (umask 077; printf '%s\n' "$msg" > "${SRV}/state/initial-admin-password")
    echo "GUI admin password written to ${SRV}/state/initial-admin-password (root only); delete it after reading."
  fi
fi
