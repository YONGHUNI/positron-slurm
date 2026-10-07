# positron-slurm

Run the **Positron Remote SSH backend and Native Notebook kernels inside a Slurm allocation**.

This repository automates a workflow validated on UGA Sapelo2:

```text
Local Positron
    |
    | SSH to 127.0.0.1:22022
    v
local OpenSSH tunnel
    |
    v
Sapelo login node
    |
    v
compute node user sshd
    |
    v
Slurm job cgroup
    |
    +-- positron-server
    +-- kcserver
    +-- Pixi / Python Native Notebook kernel
```

The key property is that the user-level `sshd` is launched **inside the batch allocation**, so every process started through the Positron Remote SSH session inherits the Slurm job cgroup.

## Repository layout

- `slurm/positron-session.sbatch` — batch job that launches the job-local SSH endpoint.
- `scripts/positron-slurm-start` — submit a session from the local machine and wait until it is ready.
- `scripts/positron-slurm-stop` — cancel the current session and close the local tunnel.
- `scripts/positron-slurm-tunnel` — manage the localhost-to-compute-node tunnel.
- `examples/config.example` — local configuration.
- `examples/positron-slurm.conf` — Positron-specific SSH config example.

## Requirements

Local machine:

- OpenSSH client
- key-based SSH access to the Sapelo login node
- Positron

Sapelo:

- Slurm
- `/usr/sbin/sshd`
- `ssh-keygen`
- `ss`
- a working `~/.ssh/authorized_keys`

The defaults are tailored to Sapelo2 and use:

- shared state: `/work/whlab/$USER/.positron-slurm`
- node-local runtime: `/lscratch/$USER/positron-sshd`

Both can be changed in the batch script if needed.

## One-time local setup

Clone this repository on the machine running Positron.

```bash
git clone https://github.com/YONGHUNI/positron-slurm.git
cd positron-slurm
```

Create the local configuration:

```bash
mkdir -p ~/.config/positron-slurm
cp examples/config.example ~/.config/positron-slurm/config
$EDITOR ~/.config/positron-slurm/config
```

Create a Positron-only SSH config without modifying a Nix-managed `~/.ssh/config`:

```bash
cp examples/positron-slurm.conf ~/.ssh/positron-slurm.conf
$EDITOR ~/.ssh/positron-slurm.conf
chmod 600 ~/.ssh/positron-slurm.conf
```

For the tested Positron setup, add to local User Settings JSON:

```json
{
  "remoteSSH.configFile": "/home/YOUR_LOCAL_USER/.ssh/positron-slurm.conf",
  "remoteSSH.serverInstallPath": {
    "sapelo-slurm": "/work/whlab/$USER/.positron-server-slurm"
  }
}
```

The localhost tunnel deliberately keeps `ProxyCommand` and `ProxyJump` out of Positron's SSH config. This avoids parser limitations in older Positron Remote SSH builds while leaving routing to the system OpenSSH client.

## Start a session

From the local machine:

```bash
./scripts/positron-slurm-start
```

The default allocation is 4 CPUs, 16 GiB RAM, and 4 hours. Override Slurm resources by passing normal `sbatch` options:

```bash
./scripts/positron-slurm-start \
  --cpus-per-task=8 \
  --mem=32G \
  --time=08:00:00
```

When ready, connect Positron to:

```text
sapelo-slurm
```

## Stop a session

```bash
./scripts/positron-slurm-stop
```

This cancels the current Slurm job and closes the local SSH tunnel.

## Verify that Positron is inside Slurm

In the Positron remote terminal:

```bash
hostname
echo "$SLURM_JOB_ID"
cat /proc/$$/cgroup
```

The cgroup should contain the current job ID, for example:

```text
0::/system.slice/slurmstepd.scope/job_48850453/step_0/user/task_0
```

In a Positron Native Notebook:

```python
import os
import pathlib
import socket
import sys

print("Python:", sys.executable)
print("Host:", socket.gethostname())
print("Job:", os.environ.get("SLURM_JOB_ID"))
print("Cgroup:", pathlib.Path("/proc/self/cgroup").read_text().strip())
```

The notebook kernel should report the compute node and the same Slurm job cgroup.

## Rootless Nix / Pixi

This project does not install Nix or Pixi. On systems where rootless Nix is needed, bootstrap it separately before using Nix-backed Pixi environments.

For the author's Sapelo workflow, rootless Nix is maintained separately in:

```text
YONGHUNI/rootless-nix-bootstrap
```

## Security notes

- Password and keyboard-interactive authentication are disabled for the job-local `sshd`.
- Only the current user is allowed to authenticate.
- The SSH host key is persisted in the user's private shared directory so the `sapelo-slurm` alias has a stable host identity across allocations.
- The SSH daemon listens on a high unprivileged port on the compute node and is reachable through the Sapelo login node.
- Check the HPC site's policy before using this pattern on another cluster.
