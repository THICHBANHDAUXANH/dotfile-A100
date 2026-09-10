#!/usr/bin/env bash
# setup.sh — dotfile-A100
#
# Usage:
#   bash setup.sh           → startup mode  (mỗi khi pod restart, ~10s)
#   bash setup.sh install   → install mode  (lần đầu tiên, ~3 phút)

MODE="${1:-startup}"

set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }

DATA=/home/data
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PATH="$DATA/.local/bin:$DATA/.npm-global/bin:$PATH"
export NVM_DIR="$DATA/.nvm"
export UV_TOOL_DIR="$DATA/.uv/tools"
export UV_TOOL_BIN_DIR="$DATA/.local/bin"
export UV_INSTALL_DIR="$DATA/.local/bin"
export NPM_CONFIG_PREFIX="$DATA/.npm-global"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ "$MODE" == "install" ]]; then
    info "dotfile-A100 INSTALL — $(date)"
else
    info "Pod startup — $(date)"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ══════════════════════════════════════════════════════════════════════════
# INSTALL-ONLY FUNCTIONS  (chạy 1 lần duy nhất)
# ══════════════════════════════════════════════════════════════════════════

install_uv() {
    if [[ -x "$DATA/.local/bin/uv" ]]; then
        ok "uv already installed: $($DATA/.local/bin/uv --version)"; return
    fi
    info "Installing uv → $DATA/.local/bin ..."
    curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR="$DATA/.local/bin" sh
    ok "uv installed: $(uv --version)"
}

install_huggingface() {
    if [[ -x "$DATA/.local/bin/hf" ]]; then ok "hf already installed"; return; fi
    info "Installing huggingface-cli & hf ..."
    uv tool install "huggingface_hub[cli]"
    curl -LsSf https://hf.co/cli/install.sh | bash -s || true
    local hf_venv="$HOME/.hf-cli/venv"
    local hf_bin="$DATA/.local/bin/hf"
    if [[ -f "$hf_venv/bin/python3" ]] && ! "$hf_bin" sync --help &>/dev/null 2>&1; then
        cat > "$hf_bin" << HFEOF
#!${hf_venv}/bin/python3
import sys
sys.path = [p for p in sys.path if '/opt/venv' not in p]
from huggingface_hub.cli.hf import main
main()
HFEOF
        chmod +x "$hf_bin"
    fi
    ok "hf installed"
}

install_hf_xet() {
    for python in /opt/venv/bin/python3 "$HOME/.hf-cli/venv/bin/python3"; do
        [[ -x "$python" ]] || continue
        "$python" -c "import huggingface_hub" 2>/dev/null || continue
        "$python" -c "import hf_xet" 2>/dev/null && continue
        info "Installing hf_xet into $(dirname "$python")..."
        "$python" -m pip install -q hf_xet
    done
    ok "hf_xet installed"
}

install_nvitop() {
    if [[ -x "$DATA/.local/bin/nvitop" ]]; then ok "nvitop already installed"; return; fi
    info "Installing nvitop ..."
    uv tool install nvitop
    ok "nvitop installed"
}

install_pm2() {
    if [[ -x "$DATA/.npm-global/bin/pm2" ]]; then
        ok "pm2 already installed: $($DATA/.npm-global/bin/pm2 --version)"
        [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh" --no-use 2>/dev/null || true
        return
    fi
    info "Installing NVM → $NVM_DIR ..."
    if [[ ! -f "$NVM_DIR/nvm.sh" ]]; then
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | \
            NVM_DIR="$NVM_DIR" bash
    fi
    # unset NPM_CONFIG_PREFIX: nvm incompatible with it
    set +u; unset NPM_CONFIG_PREFIX; source "$NVM_DIR/nvm.sh"
    nvm install --lts; nvm use --lts; set -u
    node --version > "$DATA/.node_version"
    npm install -g pm2
    ok "pm2 installed: $(pm2 --version)"
}


setup_pm2_persist() {
    mkdir -p "$DATA/.pm2"
    if [[ ! -L /root/.pm2 ]]; then
        cp -r /root/.pm2/. "$DATA/.pm2/" 2>/dev/null || true
        rm -rf /root/.pm2
        ln -sf "$DATA/.pm2" /root/.pm2
        ok "PM2 data symlinked → $DATA/.pm2"
    fi
    pm2 save 2>/dev/null || true
    ok "PM2 state saved"
}

setup_github_ssh() {
    local data_ssh="$DATA/.ssh"
    local key="$data_ssh/id_ed25519_github"
    mkdir -p "$data_ssh" && chmod 700 "$data_ssh"
    if [[ ! -f "$key" ]]; then
        info "Generating GitHub SSH key (ed25519)..."
        ssh-keygen -t ed25519 -C "github-a100-pod" -f "$key" -N "" -q
        ok "SSH key created: $key"
    else
        ok "SSH key exists: $key"
    fi
    # Write SSH config so git always uses this key for GitHub
    cat > "$data_ssh/config" << 'EOF'
Host github.com
    IdentityFile ~/.ssh/id_ed25519_github
    StrictHostKeyChecking no
EOF
    chmod 600 "$data_ssh/config"
    [[ -f "$data_ssh/authorized_keys" ]] && \
        cp "$data_ssh/authorized_keys" "$DATA/.ssh_authorized_keys" || true
    echo ""
    echo "  ┌─ Public key (add to GitHub > Settings > SSH keys) ─────────"
    sed 's/^/  │  /' "$key.pub"
    echo "  └─────────────────────────────────────────────────────────────"
    echo "  https://github.com/settings/ssh/new"
    echo ""
}

configure_shell() {
    local rc_file="$HOME/.bashrc"
    local marker="# >>> dotfile-A100 managed >>>"
    if grep -qF "$marker" "$rc_file" 2>/dev/null; then ok "Shell config already patched"; return; fi
    info "Patching $rc_file..."
    cat >> "$rc_file" << SHELLBLOCK

$marker
export DATA=/home/data
export PATH="\$DATA/.local/bin:\$DATA/.npm-global/bin:\$PATH"
export NVM_DIR="\$DATA/.nvm"
export UV_TOOL_DIR="\$DATA/.uv/tools"
export UV_TOOL_BIN_DIR="\$DATA/.local/bin"
[ -s "\$NVM_DIR/nvm.sh" ] && source "\$NVM_DIR/nvm.sh" --no-use 2>/dev/null || true
# <<< dotfile-A100 managed <<<
SHELLBLOCK
    ok "Shell config updated"
}

# ══════════════════════════════════════════════════════════════════════════
# STARTUP FUNCTIONS  (chạy mỗi lần restart)
# ══════════════════════════════════════════════════════════════════════════

start_sshd() {
    # apt-get update chỉ chạy nếu sshd chưa có (pod mới, chưa install)
    if ! command -v sshd &>/dev/null; then
        info "sshd not found — installing (apt-get update + openssh-server)..."
        apt-get update -q 2>/dev/null
        apt-get install -y openssh-server libgl1 libglib2.0-0 default-jdk ncat autossh -q 2>/dev/null
    fi
    # ncat/autossh are needed by start_reverse_tunnel below -- install them
    # even if sshd was already present (e.g. base image already had sshd).
    command -v ncat &>/dev/null    || apt-get install -y ncat -q 2>/dev/null
    command -v autossh &>/dev/null || apt-get install -y autossh -q 2>/dev/null
    mkdir -p /run/sshd

    mkdir -p /root/.ssh && chmod 700 /root/.ssh

    # Restore authorized_keys từ persistent storage (worker's pubkey --
    # trusted for the loop-back `ssh -p <port> root@localhost` the worker
    # does through the reverse tunnel below).
    if [[ -f "$DATA/.ssh_authorized_keys" ]]; then
        cp "$DATA/.ssh_authorized_keys" /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
    fi

    # Tunnel key (pod → worker, used by start_reverse_tunnel's autossh).
    # Generated once and persisted immediately -- if this weren't persisted,
    # a restart would mint a new key the worker's authorized_keys no longer
    # trusts, silently breaking the tunnel.
    mkdir -p "$DATA/.ssh" && chmod 700 "$DATA/.ssh"
    local tkey="$DATA/.ssh/id_ed25519"
    if [[ ! -f "$tkey" ]]; then
        info "Generating tunnel SSH key (ed25519)..."
        ssh-keygen -t ed25519 -C "tunnel-a100-pod" -f "$tkey" -N "" -q
        ok "Tunnel key created: $tkey"
        echo ""
        echo "  ┌─ Tunnel public key (add to the WORKER's ~/.ssh/authorized_keys) ─"
        sed 's/^/  │  /' "$tkey.pub"
        echo "  └───────────────────────────────────────────────────────────────────"
        echo ""
    fi
    cp "$tkey"     /root/.ssh/id_ed25519     2>/dev/null || true
    cp "$tkey.pub" /root/.ssh/id_ed25519.pub 2>/dev/null || true
    chmod 600 /root/.ssh/id_ed25519 2>/dev/null || true

    # Restore hoặc gen GitHub SSH key
    mkdir -p "$DATA/.ssh" && chmod 700 "$DATA/.ssh"
    local key="$DATA/.ssh/id_ed25519_github"
    if [[ ! -f "$key" ]]; then
        info "Generating GitHub SSH key (ed25519)..."
        ssh-keygen -t ed25519 -C "github-a100-pod" -f "$key" -N "" -q
        ok "SSH key created: $key"
    fi
    cp "$key"      /root/.ssh/id_ed25519_github     2>/dev/null || true
    cp "$key.pub"  /root/.ssh/id_ed25519_github.pub 2>/dev/null || true
    chmod 600 /root/.ssh/id_ed25519_github 2>/dev/null || true

    # SSH config cho GitHub
    cat > "$DATA/.ssh/config" << 'EOF'
Host github.com
    IdentityFile ~/.ssh/id_ed25519_github
    StrictHostKeyChecking no
EOF
    cp "$DATA/.ssh/config" /root/.ssh/config && chmod 600 /root/.ssh/config

    echo ""
    echo "  ┌─ GitHub public key (add tại github.com/settings/ssh/new) ──"
    sed 's/^/  │  /' "$key.pub"
    echo "  └────────────────────────────────────────────────────────────"
    echo ""

    /usr/sbin/sshd 2>/dev/null && ok "sshd started" || warn "sshd failed to start"
}


install_R_startup() {
    # Install R binary via apt (ephemeral, fast ~30s) + use persistent packages
    if ! command -v Rscript &>/dev/null; then
        info "Installing R (apt)..."
        apt-get install -y -q r-base 2>/dev/null
    fi
    # Point R to persistent package library
    export R_LIBS_USER="$DATA/R/library"
    mkdir -p "$R_LIBS_USER"
    # Add R_LIBS_USER to shell env permanently this session
    echo "export R_LIBS_USER=$DATA/R/library" >> /etc/environment 2>/dev/null || true
    ok "R ready: $(Rscript --version 2>&1 | head -1)  packages -> $R_LIBS_USER"
}

activate_tools() {
    # set +u: nvm.sh accesses unset vars internally, would trigger set -u exit
    set +u; unset NPM_CONFIG_PREFIX
    [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh" --no-use 2>/dev/null || true
    if [[ -f "$DATA/.node_version" ]]; then
        nvm use "$(cat "$DATA/.node_version")" 2>/dev/null || nvm use --lts 2>/dev/null || true
    else
        nvm use --lts 2>/dev/null || true
    fi
    set -u
    ok "Tools: uv=$(uv --version 2>/dev/null | awk '{print $2}'), node=$(node --version 2>/dev/null), pm2=$(pm2 --version 2>/dev/null)"
}

start_pm2() {
    if ! command -v pm2 &>/dev/null; then
        warn "pm2 not installed — run: bash setup.sh install"; return
    fi
    mkdir -p "$DATA/.pm2"
    # Symlink /root/.pm2 → persistent storage (pod restart resets /root)
    if [[ ! -L /root/.pm2 ]]; then
        rm -rf /root/.pm2
        ln -sf "$DATA/.pm2" /root/.pm2
        ok "PM2 data → $DATA/.pm2 (persistent)"
    fi
    if pm2 resurrect 2>/dev/null; then
        ok "PM2 jobs resurrected"
        pm2 list --no-color 2>/dev/null | grep -v "^$" || true
    else
        warn "PM2: no saved state — start jobs then run 'pm2 save'"
    fi
}

start_tailscale() {
    if ! command -v tailscale &>/dev/null; then
        info "Installing tailscale..."
        curl -fsSL https://tailscale.com/install.sh | sh -s -- -q
    fi
    # Multiple workloads can share this same host path (same /home/data),
    # so the tailscale state file -- which holds the node's private identity,
    # not just a display name -- MUST be unique per workload. Two containers
    # sharing one state file would both authenticate as the same tailnet
    # node and fight each other. Key it off TUNNEL_PORT when explicitly set;
    # otherwise use the plain (unsuffixed) state file, since that's what the
    # original pod already registered under -- renaming it would orphan an
    # already-authenticated node and force re-auth for no reason.
    local wid="${TUNNEL_PORT:-default}"
    local state_file
    if [[ -n "${TUNNEL_PORT:-}" ]]; then
        state_file="$DATA/tailscale-state-${TUNNEL_PORT}.json"
    else
        state_file="$DATA/tailscale-state.json"
    fi
    # /var/run (where tailscaled's default control socket lives) is
    # per-container, NOT part of the shared host path, so multiple
    # tailscaled instances across workloads don't need separate sockets --
    # only files under $DATA (the actual shared storage) need per-workload
    # names.
    pkill -f "tailscaled.*${state_file}" 2>/dev/null || true; sleep 1
    # --socks5-server: required. In --tun=userspace-networking mode (no
    # /dev/net/tun in a container) there is NO kernel route to the tailnet
    # (100.64.0.0/10) at all -- only tailscaled itself can reach peers. This
    # local SOCKS5 proxy is the only way anything else (ssh's ProxyCommand
    # via ncat, in start_reverse_tunnel below) can reach the tailnet.
    tailscaled --tun=userspace-networking --state="$state_file" \
        --socks5-server=localhost:1055 \
        > "$DATA/tailscaled-${wid}.log" 2>&1 &
    sleep 3
    # State file already holds a valid node identity from a previous `up`
    # -> no authkey needed on this and every future restart.
    if tailscale ip -4 &>/dev/null; then
        ok "Tailscale already authenticated: $(tailscale ip -4)"
        return 0
    fi
    if [[ ! -f "$DATA/.tailscale_authkey" ]]; then
        warn "No Tailscale auth key at $DATA/.tailscale_authkey and node not yet authenticated"
        warn "Get one at https://tailscale.com/settings/keys, then:"
        warn "  echo 'tskey-auth-...' > $DATA/.tailscale_authkey && bash setup.sh"
        return 1
    fi
    if tailscale up --authkey="$(cat "$DATA/.tailscale_authkey")" \
            --accept-routes --ssh --hostname="$(hostname)-${wid}" 2>/dev/null; then
        ok "Tailscale: $(tailscale ip -4)"
        return 0
    else
        warn "Tailscale auth failed — run 'tailscale up' manually"
        return 1
    fi
}

start_reverse_tunnel() {
    # Inbound TCP tới Tailscale IP của pod bị timeout (tailscaled chạy
    # userspace-networking, chỉ có DERP relay) — máy ngoài SSH vào pod
    # qua reverse tunnel này: trên worker chạy `ssh -p 2222 root@localhost`.
    local worker="hoangnv@100.102.20.26"   # bailab-worker-71
    local worker_ssh_port=2209             # worker's own sshd -- verify with: ss -tlnp | grep sshd (trên worker)
    # Override per-workload via the TUNNEL_PORT env var (set it once in the
    # RunAI workload's environment variables so it persists across restarts
    # of that same workload -- no more editing this file by hand). Defaults
    # to 2222 for backwards compatibility with the original pod.
    local port="${TUNNEL_PORT:-2222}"
    local wid="${TUNNEL_PORT:-default}"
    if pgrep -f "ssh.*-R ${port}:localhost:22" >/dev/null 2>&1; then
        ok "Reverse tunnel already running (port $port)"; return
    fi
    if [[ ! -f "$DATA/.ssh/id_ed25519" ]]; then
        warn "No tunnel key at $DATA/.ssh/id_ed25519 -- start_sshd should have created it, skipping tunnel"
        return 1
    fi
    # ProxyCommand bắt buộc: userspace-networking nên outbound tới tailnet
    # không có kernel route -- phải đi qua SOCKS5 proxy mà tailscaled expose
    # (--socks5-server, xem start_tailscale). Dùng ncat vì syntax SOCKS5 ổn
    # định hơn socat (đã thử socat và fail: "socksport not supported").
    # Auth bằng SSH key (/home/data/.ssh/id_ed25519, persistent qua restart) --
    # public key của nó phải có trong ~/.ssh/authorized_keys của worker.
    # Vòng while tự reconnect khi tunnel đứt.
    nohup bash -c "while true; do
        ssh -i '$DATA/.ssh/id_ed25519' \
            -o ProxyCommand='ncat --proxy 127.0.0.1:1055 --proxy-type socks5 %h %p' \
            -o StrictHostKeyChecking=no \
            -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
            -o ExitOnForwardFailure=yes \
            -p ${worker_ssh_port} \
            -R ${port}:localhost:22 ${worker} -N
        sleep 5
    done" > "$DATA/tunnel-${wid}.log" 2>&1 &
    ok "Reverse tunnel → ${worker}:${worker_ssh_port} (trên worker: ssh -p ${port} root@localhost)"
}


# ══════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════

if [[ "$MODE" == "install" ]]; then
    # ── First-time install ───────────────────────────────────────────────
    apt-get update -q 2>/dev/null
    install_uv
    install_huggingface
    install_hf_xet
    install_nvitop
    install_pm2
    setup_pm2_persist
    configure_shell
    setup_github_ssh

    # Deploy this script itself to /home/data/ for startup use
    cp "$SCRIPT_DIR/setup.sh" "$DATA/setup.sh" && chmod +x "$DATA/setup.sh"
    ok "setup.sh deployed → $DATA/setup.sh"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    ok "INSTALL DONE — $(date)"
    echo ""
    echo "  Next steps:"
    echo "    echo 'tskey-auth-...' > $DATA/.tailscale_authkey"
    echo "    bash $DATA/setup.sh          ← chạy startup ngay"
    echo "    hf auth login"
    echo "    ssh -T git@github.com"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo -e "${YELLOW}  ⚠ Activate ngay:${NC}  source ~/.bashrc"

else
    # ── Every-restart startup ────────────────────────────────────────────
    start_sshd
    activate_tools
    start_pm2

    start_tailscale && start_reverse_tunnel

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    ok "STARTUP DONE — $(date)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi
