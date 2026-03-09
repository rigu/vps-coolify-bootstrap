#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-/etc/vps-coolify-bootstrap/bootstrap.env}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/common.sh"
bootstrap_install_error_trap "verify-bootstrap-state.sh"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  bootstrap_error "run as root (for example: sudo bash scripts/verify-bootstrap-state.sh ...)."
  exit 1
fi

load_env_file_strict "$ENV_FILE"

CLOSE_COOLIFY_REALTIME_PORTS="${CLOSE_COOLIFY_REALTIME_PORTS:-}"
if [[ -z "$CLOSE_COOLIFY_REALTIME_PORTS" ]] && [[ -n "${ALLOW_PUBLIC_COOLIFY_REALTIME_PORTS:-}" ]]; then
  if [[ "$ALLOW_PUBLIC_COOLIFY_REALTIME_PORTS" == "0" ]]; then
    CLOSE_COOLIFY_REALTIME_PORTS="true"
  elif [[ "$ALLOW_PUBLIC_COOLIFY_REALTIME_PORTS" == "1" ]]; then
    CLOSE_COOLIFY_REALTIME_PORTS="false"
  fi
fi
CLOSE_COOLIFY_REALTIME_PORTS="${CLOSE_COOLIFY_REALTIME_PORTS:-false}"
invalid_close_coolify_realtime_ports=""
case "$CLOSE_COOLIFY_REALTIME_PORTS" in
  true|false) ;;
  1) CLOSE_COOLIFY_REALTIME_PORTS="true" ;;
  0) CLOSE_COOLIFY_REALTIME_PORTS="false" ;;
  *)
    invalid_close_coolify_realtime_ports="$CLOSE_COOLIFY_REALTIME_PORTS"
    CLOSE_COOLIFY_REALTIME_PORTS="false"
    ;;
esac

DOCKER_DISABLE_IPV6_FOR_PARSEADDR_FIX="${DOCKER_DISABLE_IPV6_FOR_PARSEADDR_FIX:-true}"
invalid_docker_disable_ipv6_for_parseaddr_fix=""
case "$DOCKER_DISABLE_IPV6_FOR_PARSEADDR_FIX" in
  true|false) ;;
  1) DOCKER_DISABLE_IPV6_FOR_PARSEADDR_FIX="true" ;;
  0) DOCKER_DISABLE_IPV6_FOR_PARSEADDR_FIX="false" ;;
  *)
    invalid_docker_disable_ipv6_for_parseaddr_fix="$DOCKER_DISABLE_IPV6_FOR_PARSEADDR_FIX"
    DOCKER_DISABLE_IPV6_FOR_PARSEADDR_FIX="true"
    ;;
esac

COOLIFY_SUDO_NOPASSWD_USER="${COOLIFY_SUDO_NOPASSWD_USER:-coolify}"
DEVOPS_USER="${DEVOPS_USER:-devops}"
COOLIFY_REALTIME_DOMAIN="${COOLIFY_REALTIME_DOMAIN:-}"
COOLIFY_PUBLIC_DOMAIN="${COOLIFY_PUBLIC_DOMAIN:-}"
EFFECTIVE_COOLIFY_REALTIME_DOMAIN="$COOLIFY_REALTIME_DOMAIN"
if [[ "$CLOSE_COOLIFY_REALTIME_PORTS" == "true" ]] && [[ -z "$EFFECTIVE_COOLIFY_REALTIME_DOMAIN" ]]; then
  EFFECTIVE_COOLIFY_REALTIME_DOMAIN="$COOLIFY_PUBLIC_DOMAIN"
fi

managed_users_csv="$DEVOPS_USER"
managed_users_csv="$(csv_append_unique "$managed_users_csv" "$COOLIFY_SUDO_NOPASSWD_USER")"
for user in $(split_csv_to_lines "${ADDITIONAL_SUDO_USERS:-}"); do
  managed_users_csv="$(csv_append_unique "$managed_users_csv" "$user")"
done

failures=0
warnings=0
has_iptables_600x_drop=unknown
has_ip6tables_600x_drop=unknown

pass() {
  printf '[%s] PASS [%s] %s\n' "$(bootstrap_log_ts)" "${BOOTSTRAP_LOG_CONTEXT:-verify-bootstrap-state.sh}" "$1"
}

warn() {
  warnings=$((warnings + 1))
  printf '[%s] WARN [%s] %s\n' "$(bootstrap_log_ts)" "${BOOTSTRAP_LOG_CONTEXT:-verify-bootstrap-state.sh}" "$1"
}

fail() {
  failures=$((failures + 1))
  printf '[%s] FAIL [%s] %s\n' "$(bootstrap_log_ts)" "${BOOTSTRAP_LOG_CONTEXT:-verify-bootstrap-state.sh}" "$1"
}

if [[ -n "$invalid_close_coolify_realtime_ports" ]]; then
  warn "invalid CLOSE_COOLIFY_REALTIME_PORTS value '${invalid_close_coolify_realtime_ports}' in env; treating as false"
fi
if [[ -n "$invalid_docker_disable_ipv6_for_parseaddr_fix" ]]; then
  warn "invalid DOCKER_DISABLE_IPV6_FOR_PARSEADDR_FIX value '${invalid_docker_disable_ipv6_for_parseaddr_fix}' in env; treating as true"
fi

check_service_state() {
  local unit="$1"
  local expected="$2"
  local actual=""
  actual="$(systemctl is-active "$unit" 2>/dev/null || true)"
  if [[ "$actual" == "$expected" ]]; then
    pass "$unit is $expected"
  else
    fail "$unit is $actual (expected $expected)"
  fi
}

check_service_enabled_state() {
  local unit="$1"
  local expected="$2"
  local actual=""
  actual="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  if [[ "$actual" == "$expected" ]]; then
    pass "$unit is-enabled = $expected"
  else
    fail "$unit is-enabled = $actual (expected $expected)"
  fi
}

check_member_of_group() {
  local user="$1"
  local group="$2"
  if id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$group"; then
    pass "user $user is in group $group"
  else
    fail "user $user is missing group $group"
  fi
}

echo "=== SSH service baseline ==="
check_service_enabled_state ssh.socket disabled
check_service_state ssh.socket inactive
check_service_enabled_state ssh.service enabled
check_service_state ssh.service active

if ss -lnt "( sport = :${SSH_PORT} )" 2>/dev/null | grep -q ":${SSH_PORT}"; then
  pass "sshd listens on configured SSH_PORT=${SSH_PORT}"
else
  fail "sshd does not listen on configured SSH_PORT=${SSH_PORT}"
fi

if [[ "${SSH_PORT}" != "22" ]]; then
  if ss -lnt "( sport = :22 )" 2>/dev/null | grep -q ':22'; then
    fail "port 22 still has a listener while SSH_PORT=${SSH_PORT}"
  else
    pass "no listener on port 22"
  fi
fi

echo "=== Firewall baseline ==="
if command -v ufw >/dev/null 2>&1; then
  ufw_status="$(ufw status verbose 2>/dev/null || true)"
  if grep -Eq "^[[:space:]]*${SSH_PORT}/tcp[[:space:]]+LIMIT IN" <<<"$ufw_status"; then
    pass "UFW has LIMIT IN rule for SSH_PORT=${SSH_PORT}"
  else
    fail "UFW missing LIMIT IN rule for SSH_PORT=${SSH_PORT}"
  fi
  if grep -Eq "^[[:space:]]*80/tcp[[:space:]]+ALLOW IN" <<<"$ufw_status" && \
     grep -Eq "^[[:space:]]*443/tcp[[:space:]]+ALLOW IN" <<<"$ufw_status"; then
    pass "UFW allows 80/tcp and 443/tcp"
  else
    fail "UFW missing 80/tcp or 443/tcp allow rule"
  fi
else
  warn "ufw command not found; skipping firewall checks"
fi

echo "=== User and sudo policy ==="
while IFS= read -r user; do
  if id "$user" >/dev/null 2>&1; then
    pass "user exists: $user"
  else
    fail "missing user: $user"
  fi
done < <(split_csv_to_lines "$managed_users_csv")

while IFS= read -r user; do
  check_member_of_group "$user" "sudo"
  check_member_of_group "$user" "docker"
  check_member_of_group "$user" "coolify"
done < <(split_csv_to_lines "$managed_users_csv")

if grep -Eq "^${DEVOPS_USER}[[:space:]]+ALL=\\(ALL:ALL\\)[[:space:]]+NOPASSWD:ALL$" /etc/sudoers.d/99-bootstrap-sudo-policy 2>/dev/null; then
  pass "DEVOPS_USER has NOPASSWD sudo policy (${DEVOPS_USER})"
else
  fail "DEVOPS_USER missing NOPASSWD policy (${DEVOPS_USER})"
fi

if grep -Eq "^${COOLIFY_SUDO_NOPASSWD_USER}[[:space:]]+ALL=\\(ALL:ALL\\)[[:space:]]+NOPASSWD:ALL$" /etc/sudoers.d/99-bootstrap-sudo-policy 2>/dev/null; then
  pass "COOLIFY_SUDO_NOPASSWD_USER has NOPASSWD policy (${COOLIFY_SUDO_NOPASSWD_USER})"
else
  fail "COOLIFY_SUDO_NOPASSWD_USER missing NOPASSWD policy (${COOLIFY_SUDO_NOPASSWD_USER})"
fi

echo "=== Coolify runtime ==="
if ! command -v docker >/dev/null 2>&1; then
  fail "docker command not found"
else
  docker_version="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
  docker_major="${docker_version%%.*}"
  docker_ipv6_enabled="$(docker info --format '{{.IPv6}}' 2>/dev/null || true)"

  if [[ "$DOCKER_DISABLE_IPV6_FOR_PARSEADDR_FIX" == "true" ]]; then
    if [[ "$docker_major" =~ ^[0-9]+$ ]] && (( 10#$docker_major < 28 )); then
      if [[ "$docker_ipv6_enabled" == "false" ]]; then
        pass "Docker ParseAddr workaround active for Docker ${docker_version} (daemon IPv6 disabled)"
      else
        fail "Docker ${docker_version} with daemon IPv6 enabled; expected ipv6=false to avoid ParseAddr(\".../64\") proxy failure"
      fi
    else
      pass "Docker ParseAddr workaround policy enabled (Docker ${docker_version:-unknown})"
    fi
  else
    warn "Docker ParseAddr workaround disabled by env (DOCKER_DISABLE_IPV6_FOR_PARSEADDR_FIX=false)"
  fi

  cidr_gateway_detected=0
  while IFS= read -r net_id; do
    [[ -n "$net_id" ]] || continue
    gateways="$(docker network inspect "$net_id" --format '{{range .IPAM.Config}}{{if .Gateway}}{{println .Gateway}}{{end}}{{end}}' 2>/dev/null || true)"
    if grep -Eq ':[0-9A-Fa-f:]+/[0-9]+' <<<"$gateways"; then
      cidr_gateway_detected=1
      break
    fi
  done < <(docker network ls -q 2>/dev/null || true)
  if (( cidr_gateway_detected == 1 )); then
    if [[ "$DOCKER_DISABLE_IPV6_FOR_PARSEADDR_FIX" == "true" ]]; then
      fail "Docker network inspect still reports IPv6 gateway CIDR (/64); Start Proxy may fail with ParseAddr"
    else
      warn "Docker network inspect reports IPv6 gateway CIDR (/64) and workaround is disabled"
    fi
  else
    pass "Docker network inspect does not report IPv6 gateway CIDR for IPv6 gateways"
  fi

  if docker ps --format '{{.Names}}' | grep -qx 'coolify'; then
    pass "coolify container is running"
  else
    fail "coolify container is not running"
  fi
  if docker ps --format '{{.Names}}' | grep -Eq '^coolify-proxy($|_)'; then
    pass "coolify proxy container is running"
  else
    warn "coolify proxy container is not running yet (expected before onboarding/domain proxy setup)"
  fi
fi

if ss -lnt | awk '{print $4}' | grep -Eq '(^|[:.])80$'; then
  pass "port 80 listener exists for Coolify proxy"
else
  warn "port 80 listener missing (expected before onboarding/domain proxy setup)"
fi
if ss -lnt | awk '{print $4}' | grep -Eq '(^|[:.])443$'; then
  pass "port 443 listener exists for Coolify proxy"
else
  warn "port 443 listener missing (expected before onboarding/domain proxy setup)"
fi

coolify_local_key="/data/coolify/ssh/keys/id.${COOLIFY_SUDO_NOPASSWD_USER}@host.docker.internal"
coolify_local_pub="${coolify_local_key}.pub"
if [[ -s "$coolify_local_key" && -s "$coolify_local_pub" ]]; then
  pass "dedicated Coolify localhost SSH key exists for ${COOLIFY_SUDO_NOPASSWD_USER}"
else
  fail "missing dedicated Coolify localhost SSH key for ${COOLIFY_SUDO_NOPASSWD_USER}"
fi

coolify_user_home="$(getent passwd "$COOLIFY_SUDO_NOPASSWD_USER" | cut -d: -f6 || true)"
if [[ -n "$coolify_user_home" ]] && [[ -f "${coolify_user_home}/.ssh/authorized_keys" ]] && [[ -f "$coolify_local_pub" ]]; then
  local_pub_key="$(cat "$coolify_local_pub")"
  if grep -Fq -- "$local_pub_key" "${coolify_user_home}/.ssh/authorized_keys"; then
    if grep -F -- "$local_pub_key" "${coolify_user_home}/.ssh/authorized_keys" | grep -q 'from="'; then
      pass "Coolify localhost public key is present with source restriction in ${COOLIFY_SUDO_NOPASSWD_USER} authorized_keys"
    else
      fail "Coolify localhost public key exists but is missing source restriction in ${COOLIFY_SUDO_NOPASSWD_USER} authorized_keys"
    fi
  else
    fail "Coolify localhost public key missing in ${COOLIFY_SUDO_NOPASSWD_USER} authorized_keys"
  fi

  if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
    if grep -Fxq -- "${SSH_PUBLIC_KEY}" "${coolify_user_home}/.ssh/authorized_keys"; then
      fail "operator SSH key should not be present in ${COOLIFY_SUDO_NOPASSWD_USER} authorized_keys"
    else
      pass "operator SSH key is not present in ${COOLIFY_SUDO_NOPASSWD_USER} authorized_keys"
    fi
  else
    pass "operator SSH key not configured in bootstrap.env; skip operator-key absence check"
  fi
else
  fail "cannot validate ${COOLIFY_SUDO_NOPASSWD_USER} authorized_keys against Coolify localhost key"
fi

if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -qx 'coolify'; then
  if db_state="$(docker exec -e BOOTSTRAP_ROOT_EMAIL="${COOLIFY_ROOT_USER_EMAIL:-}" -i coolify php <<'PHP'
<?php
chdir('/var/www/html');
require '/var/www/html/vendor/autoload.php';
$app = require '/var/www/html/bootstrap/app.php';
$kernel = $app->make(\Illuminate\Contracts\Console\Kernel::class);
$kernel->bootstrap();
$server = \App\Models\Server::find(0);
if (! $server) {
    fwrite(STDERR, "server id 0 not found\n");
    exit(21);
}
echo 'server_user=' . $server->user . PHP_EOL;
echo 'server_ip=' . $server->ip . PHP_EOL;
echo 'server_port=' . $server->port . PHP_EOL;
echo 'server_private_key_id=' . $server->private_key_id . PHP_EOL;
echo 'server_proxy_type=' . ($server->proxyType() ?? '') . PHP_EOL;
$settings = \App\Models\InstanceSettings::get();
echo 'instance_fqdn=' . ($settings->fqdn ?? '') . PHP_EOL;
$rootEmail = strtolower((string) getenv('BOOTSTRAP_ROOT_EMAIL'));
$rootQuery = \App\Models\User::query()->where('id', 0);
if ($rootEmail !== '') {
    $rootQuery->orWhere('email', $rootEmail);
}
echo 'root_user_exists=' . ($rootQuery->exists() ? '1' : '0') . PHP_EOL;
PHP
)"; then
    server_user="$(sed -n 's/^server_user=//p' <<<"$db_state" | tail -n1)"
    server_ip="$(sed -n 's/^server_ip=//p' <<<"$db_state" | tail -n1)"
    server_port="$(sed -n 's/^server_port=//p' <<<"$db_state" | tail -n1)"
    server_proxy_type="$(sed -n 's/^server_proxy_type=//p' <<<"$db_state" | tail -n1)"
    instance_fqdn="$(sed -n 's/^instance_fqdn=//p' <<<"$db_state" | tail -n1)"
    root_user_exists="$(sed -n 's/^root_user_exists=//p' <<<"$db_state" | tail -n1)"
    if [[ "$server_user" == "$COOLIFY_SUDO_NOPASSWD_USER" ]]; then
      pass "Coolify localhost server user is ${COOLIFY_SUDO_NOPASSWD_USER}"
    else
      fail "Coolify localhost server user is ${server_user} (expected ${COOLIFY_SUDO_NOPASSWD_USER})"
    fi
    if [[ "$server_ip" == "host.docker.internal" ]]; then
      pass "Coolify localhost server host is host.docker.internal"
    else
      fail "Coolify localhost server host is ${server_ip} (expected host.docker.internal)"
    fi
    if [[ "$server_port" == "$SSH_PORT" ]]; then
      pass "Coolify localhost server port is ${SSH_PORT}"
    else
      fail "Coolify localhost server port is ${server_port} (expected ${SSH_PORT})"
    fi
    if [[ -n "$server_proxy_type" && "$server_proxy_type" != "NONE" ]]; then
      pass "Coolify localhost server proxy type is ${server_proxy_type}"
    else
      warn "Coolify localhost server proxy type is ${server_proxy_type:-<empty>} (proxy may not be finalized before onboarding)"
    fi
    expected_instance_fqdn="https://${COOLIFY_PUBLIC_DOMAIN}"
    if [[ "$instance_fqdn" == "$expected_instance_fqdn" ]]; then
      pass "Instance fqdn is ${expected_instance_fqdn}"
    else
      warn "Instance fqdn is ${instance_fqdn:-<empty>} (expected ${expected_instance_fqdn} after onboarding)"
    fi
    if [[ "$root_user_exists" == "1" ]]; then
      pass "Coolify root user exists (id=0 or configured root email)"
    else
      fail "Coolify root user missing (expected id=0 or configured root email)"
    fi

    if docker exec -e BOOTSTRAP_LOCALHOST_HOST="$server_ip" -e BOOTSTRAP_LOCALHOST_PORT="$server_port" coolify php -r '
      $h = getenv("BOOTSTRAP_LOCALHOST_HOST");
      $p = (int) getenv("BOOTSTRAP_LOCALHOST_PORT");
      $s = @fsockopen($h, $p, $errno, $errstr, 3);
      exit($s ? 0 : 1);
    ' >/dev/null 2>&1; then
      pass "Coolify container can reach localhost server endpoint ${server_ip}:${server_port}"
    else
      fail "Coolify container cannot reach localhost server endpoint ${server_ip}:${server_port}"
    fi
  else
    fail "unable to read Coolify localhost server state from container"
  fi
fi

echo "=== Realtime host and 6001/6002 policy ==="
coolify_env="/data/coolify/source/.env"
if [[ -f "$coolify_env" ]]; then
  env_pusher_host="$(sed -n 's/^PUSHER_HOST=//p' "$coolify_env" | tail -n1 || true)"
  env_pusher_port="$(sed -n 's/^PUSHER_PORT=//p' "$coolify_env" | tail -n1 || true)"
  env_pusher_scheme="$(sed -n 's/^PUSHER_SCHEME=//p' "$coolify_env" | tail -n1 || true)"
else
  env_pusher_host=""
  env_pusher_port=""
  env_pusher_scheme=""
  warn "Coolify env file missing: $coolify_env"
fi

if [[ "$CLOSE_COOLIFY_REALTIME_PORTS" == "true" ]] && [[ -z "$EFFECTIVE_COOLIFY_REALTIME_DOMAIN" ]]; then
  fail "closed realtime mode requires effective domain via COOLIFY_REALTIME_DOMAIN or COOLIFY_PUBLIC_DOMAIN"
fi

if [[ -n "${EFFECTIVE_COOLIFY_REALTIME_DOMAIN:-}" ]]; then
  expected_realtime_source="COOLIFY_REALTIME_DOMAIN"
  if [[ -z "$COOLIFY_REALTIME_DOMAIN" ]]; then
    expected_realtime_source="COOLIFY_PUBLIC_DOMAIN fallback"
  fi

  if [[ "$env_pusher_host" == "$EFFECTIVE_COOLIFY_REALTIME_DOMAIN" ]]; then
    pass "PUSHER_HOST matches effective realtime domain (${EFFECTIVE_COOLIFY_REALTIME_DOMAIN}, source=${expected_realtime_source})"
  else
    fail "PUSHER_HOST is ${env_pusher_host:-<empty>} (expected ${EFFECTIVE_COOLIFY_REALTIME_DOMAIN}, source=${expected_realtime_source})"
  fi
  if [[ "$env_pusher_port" == "443" ]]; then
    pass "PUSHER_PORT is 443 for dedicated realtime host"
  else
    fail "PUSHER_PORT is ${env_pusher_port:-<empty>} (expected 443)"
  fi
  if [[ "$env_pusher_scheme" == "https" ]]; then
    pass "PUSHER_SCHEME is https for dedicated realtime host"
  else
    fail "PUSHER_SCHEME is ${env_pusher_scheme:-<empty>} (expected https)"
  fi
  if [[ "$CLOSE_COOLIFY_REALTIME_PORTS" == "false" ]]; then
    pass "realtime routing via dedicated host is configured on https/443 even with CLOSE_COOLIFY_REALTIME_PORTS=false"
  else
    pass "realtime routing via dedicated host is configured on https/443 with CLOSE_COOLIFY_REALTIME_PORTS=true"
    if ss -lnt | awk '{print $4}' | grep -Eq '(^|[:.])443$'; then
      pass "port 443 listener exists for domain/reverse-proxy path"
    else
      warn "no local listener detected on port 443; verify reverse-proxy readiness"
    fi
    if command -v getent >/dev/null 2>&1; then
      if getent ahosts "$EFFECTIVE_COOLIFY_REALTIME_DOMAIN" >/dev/null 2>&1; then
        pass "DNS resolution works for effective realtime domain (${EFFECTIVE_COOLIFY_REALTIME_DOMAIN})"
      else
        warn "DNS resolution failed for effective realtime domain (${EFFECTIVE_COOLIFY_REALTIME_DOMAIN})"
      fi
    fi
  fi
else
  if [[ -z "$env_pusher_host" && -z "$env_pusher_port" && -z "$env_pusher_scheme" ]]; then
    pass "PUSHER_HOST/PUSHER_PORT/PUSHER_SCHEME are unset (no dedicated realtime host configured)"
  else
    warn "dedicated realtime host vars remain set in Coolify env while COOLIFY_REALTIME_DOMAIN is empty"
  fi
fi

base_compose="/data/coolify/source/docker-compose.yml"
prod_compose="/data/coolify/source/docker-compose.prod.yml"
if [[ -f "$base_compose" && -f "$prod_compose" ]]; then
  if grep -Eq '^[[:space:]]*-[[:space:]]*"[^"]*:8080"' "$base_compose" \
    || grep -Eq '^[[:space:]]*-[[:space:]]*"[^"]*:8080"' "$prod_compose"; then
    warn "Coolify compose publishes 8080 via host mapping (official installer default for onboarding on :8000)"
  else
    pass "Coolify compose does not publish 8080 via host port mapping"
  fi
  if [[ "$CLOSE_COOLIFY_REALTIME_PORTS" == "true" ]]; then
    if grep -Eq '^([[:space:]]*)ports:[[:space:]]*$' "$prod_compose" \
      && grep -Eq '^[[:space:]]*-[[:space:]]*"\$\{SOKETI_PORT:-6001\}:6001"' "$prod_compose" \
      && grep -Eq '^[[:space:]]*-[[:space:]]*"6002:6002"' "$prod_compose"; then
      warn "Coolify prod compose still publishes Soketi ports 6001/6002; DOCKER-USER guards must enforce closed mode"
    else
      pass "Coolify prod compose does not publish Soketi ports 6001/6002"
    fi
  fi
else
  warn "Coolify compose files missing; skipped compose inspection"
fi

if command -v iptables >/dev/null 2>&1 && iptables -nL DOCKER-USER >/dev/null 2>&1; then
  if [[ "$CLOSE_COOLIFY_REALTIME_PORTS" == "true" ]]; then
    if iptables -C DOCKER-USER -p tcp -m multiport --dports 6001,6002 -j DROP >/dev/null 2>&1; then
      has_iptables_600x_drop=true
      pass "iptables DOCKER-USER DROP guard exists for 6001/6002"
    else
      has_iptables_600x_drop=false
      fail "iptables DOCKER-USER DROP guard missing for 6001/6002"
    fi
  else
    if iptables -C DOCKER-USER -p tcp -m multiport --dports 6001,6002 -j DROP >/dev/null 2>&1; then
      warn "iptables DOCKER-USER DROP guard exists even though CLOSE_COOLIFY_REALTIME_PORTS=false"
    else
      pass "no iptables DOCKER-USER DROP guard for 6001/6002 (expected with CLOSE_COOLIFY_REALTIME_PORTS=false)"
    fi
  fi
else
  warn "iptables/DOCKER-USER not available; skipped IPv4 6001/6002 guard verification"
fi

if command -v ip6tables >/dev/null 2>&1 && ip6tables -nL DOCKER-USER >/dev/null 2>&1; then
  if [[ "$CLOSE_COOLIFY_REALTIME_PORTS" == "true" ]]; then
    if ip6tables -C DOCKER-USER -p tcp -m multiport --dports 6001,6002 -j DROP >/dev/null 2>&1; then
      has_ip6tables_600x_drop=true
      pass "ip6tables DOCKER-USER DROP guard exists for 6001/6002"
    else
      has_ip6tables_600x_drop=false
      fail "ip6tables DOCKER-USER DROP guard missing for 6001/6002"
    fi
  else
    if ip6tables -C DOCKER-USER -p tcp -m multiport --dports 6001,6002 -j DROP >/dev/null 2>&1; then
      warn "ip6tables DOCKER-USER DROP guard exists even though CLOSE_COOLIFY_REALTIME_PORTS=false"
    else
      pass "no ip6tables DOCKER-USER DROP guard for 6001/6002 (expected with CLOSE_COOLIFY_REALTIME_PORTS=false)"
    fi
  fi
else
  warn "ip6tables/DOCKER-USER not available; skipped IPv6 6001/6002 guard verification"
fi

if ss -lnt | awk '{print $4}' | grep -Eq '[:.]6001$|[:.]6002$'; then
  if [[ "$CLOSE_COOLIFY_REALTIME_PORTS" == "true" ]]; then
    if [[ "$has_iptables_600x_drop" == "true" ]]; then
      pass "ports 6001/6002 listen, but IPv4 public ingress is blocked by DOCKER-USER"
    elif [[ "$has_iptables_600x_drop" == "false" ]]; then
      fail "ports 6001/6002 listen and IPv4 DOCKER-USER DROP guard is missing"
    else
      warn "ports 6001/6002 listen and IPv4 guard state could not be verified"
    fi
    if [[ "$has_ip6tables_600x_drop" == "true" ]]; then
      pass "ports 6001/6002 IPv6 public ingress is blocked by DOCKER-USER"
    elif [[ "$has_ip6tables_600x_drop" == "false" ]]; then
      fail "ports 6001/6002 listen and IPv6 DOCKER-USER DROP guard is missing"
    fi
  else
    pass "ports 6001/6002 are listening (expected when CLOSE_COOLIFY_REALTIME_PORTS=false)"
  fi
else
  pass "ports 6001/6002 are not listening on host"
fi

if ss -lnt | awk '{print $4}' | grep -Eq '[:.]8000$'; then
  pass "port 8000 is listening on host (official Coolify onboarding access path)"
else
  pass "port 8000 is not listening on host"
fi

if ss -lnt | awk '{print $4}' | grep -Eq '(^|[:.])80$' && \
   ss -lnt | awk '{print $4}' | grep -Eq '(^|[:.])443$'; then
  pass "ports 80/443 are listening (domain proxy path is active)"
else
  warn "ports 80/443 are not both listening yet (complete Coolify onboarding/domain proxy setup)"
fi

echo "=== Summary ==="
echo "failures: $failures"
echo "warnings: $warnings"

if (( failures > 0 )); then
  exit 1
fi

exit 0
