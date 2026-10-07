#!/usr/bin/env bash
#SBATCH --job-name=positron
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=04:00:00
#SBATCH --output=/work/whlab/%u/.positron-slurm/slurm-%j.out
#SBATCH --error=/work/whlab/%u/.positron-slurm/slurm-%j.err

set -euo pipefail

HOST="$(hostname -s)"
SHARED="/work/whlab/$USER/.positron-slurm"
RUNTIME="/lscratch/$USER/positron-sshd/$SLURM_JOB_ID"
STATE="$SHARED/current"

mkdir -p "$SHARED" "$RUNTIME"
chmod 700 "$SHARED" "$RUNTIME"

if [[ ! -s "$HOME/.ssh/authorized_keys" ]]; then
    echo "Missing or empty $HOME/.ssh/authorized_keys" >&2
    exit 1
fi

HOSTKEY="$SHARED/ssh_host_ed25519_key"
if [[ ! -s "$HOSTKEY" ]]; then
    umask 077
    ssh-keygen -q -t ed25519 -N '' -f "$HOSTKEY"
fi

START=$((20000 + SLURM_JOB_ID % 20000))
PORT=""

for ((i=0; i<200; i++)); do
    candidate=$((20000 + (START - 20000 + i) % 20000))
    if ! ss -H -ltn | awk '{print $4}' | grep -q ":${candidate}$"; then
        PORT="$candidate"
        break
    fi
done

: "${PORT:?Could not find a free TCP port}"

CFG="$RUNTIME/sshd_config"
LOG="$RUNTIME/sshd.log"

cat > "$CFG" <<EOF
Port $PORT
ListenAddress 0.0.0.0

HostKey $HOSTKEY
PidFile $RUNTIME/sshd.pid
AuthorizedKeysFile %h/.ssh/authorized_keys

PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no

PermitRootLogin no
AllowUsers $USER

AllowTcpForwarding yes
GatewayPorts no
X11Forwarding no
PermitTunnel no
PermitUserEnvironment no

PrintMotd no
PrintLastLog no
LogLevel VERBOSE

Subsystem sftp internal-sftp

SetEnv SLURM_JOB_ID=$SLURM_JOB_ID
SetEnv SLURM_JOB_NODELIST=$SLURM_JOB_NODELIST
EOF

/usr/sbin/sshd -t -f "$CFG"

/usr/sbin/sshd -D -e -f "$CFG" >>"$LOG" 2>&1 &
SSHD_PID=$!

sleep 1
if ! kill -0 "$SSHD_PID" 2>/dev/null; then
    echo "sshd failed to start" >&2
    cat "$LOG" >&2
    exit 1
fi

TMP="$STATE.$$"
cat > "$TMP" <<EOF
HOST=$HOST
PORT=$PORT
JOB=$SLURM_JOB_ID
EOF
chmod 600 "$TMP"
mv -f "$TMP" "$STATE"

cleanup_state() {
    if [[ -f "$STATE" ]] && grep -qx "JOB=$SLURM_JOB_ID" "$STATE"; then
        rm -f "$STATE"
    fi
}
terminate() {
    kill "$SSHD_PID" 2>/dev/null || true
}
trap cleanup_state EXIT
trap terminate TERM INT

echo "Positron Slurm session ready"
echo "HOST=$HOST"
echo "PORT=$PORT"
echo "JOB=$SLURM_JOB_ID"
echo "SSHD_PID=$SSHD_PID"
echo "CGROUP=$(cat /proc/$SSHD_PID/cgroup)"

wait "$SSHD_PID"
