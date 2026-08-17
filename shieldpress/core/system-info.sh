#!/bin/bash
# =====================================================
# ShieldPress Core - System Info Collector
# Source this file for centralized system metrics.
# All functions echo their result (no global side-effects).
# =====================================================

DOMAINS_ROOT="${DOMAINS_ROOT:-/home/domains}"

# =====================================================
# CPU / LOAD
# =====================================================

sysinfo_cpu_load(){
    uptime | awk -F'load average:' '{print $2}' | cut -d, -f1 | xargs
}

sysinfo_cpu_cores(){
    nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1
}

# =====================================================
# MEMORY
# =====================================================

sysinfo_ram_total_mb(){
    free -m | awk '/Mem:/ {print $2}'
}

sysinfo_ram_used_mb(){
    free -m | awk '/Mem:/ {print $3}'
}

sysinfo_ram_percent(){
    local total used
    total=$(sysinfo_ram_total_mb)
    used=$(sysinfo_ram_used_mb)
    [ "$total" -gt 0 ] 2>/dev/null && echo $((used * 100 / total)) || echo 0
}

sysinfo_swap_total_mb(){
    free -m | awk '/Swap:/ {print $2}'
}

sysinfo_swap_used_mb(){
    free -m | awk '/Swap:/ {print $3}'
}

# =====================================================
# DISK
# =====================================================

sysinfo_disk_percent(){
    df / | awk 'NR==2 {print $5}' | tr -d '%'
}

sysinfo_disk_used(){
    df -h / | awk 'NR==2 {print $3}'
}

sysinfo_disk_total(){
    df -h / | awk 'NR==2 {print $2}'
}

sysinfo_disk_free_mb(){
    df -m / | awk 'NR==2 {print $4}'
}

# =====================================================
# SERVICES
# =====================================================

# Check if service is running (returns 0/1)
sysinfo_service_active(){
    systemctl is-active --quiet "$1" 2>/dev/null
}

# Get service state as text: "OK" or "DOWN"
sysinfo_service_state(){
    sysinfo_service_active "$1" && echo "OK" || echo "DOWN"
}

# =====================================================
# NETWORK
# =====================================================

sysinfo_nginx_connections(){
    if [ -f /var/run/nginx.pid ]; then
        ss -s | awk '/TCP:/ {print $2}'
    else
        echo "0"
    fi
}

sysinfo_open_port_count(){
    ss -tuln | awk 'NR>1 {print $5}' | grep -oE '[0-9]+$' | sort -n | uniq | wc -l
}

sysinfo_open_ports(){
    ss -tuln | awk 'NR>1 {print $5}' | grep -oE '[0-9]+$' | sort -n | uniq | tr '\n' ' '
}

# =====================================================
# DATABASE
# =====================================================

sysinfo_mysql_queries(){
    mysqladmin status 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="Queries") print $(i+1)}'
}

sysinfo_db_public(){
    ss -tuln | grep -Eq '0\.0\.0\.0:3306|\*:3306|\[::\]:3306|:::3306|0\.0\.0\.0:5432|\*:5432|\[::\]:5432|:::5432' && echo "yes" || echo "no"
}

# =====================================================
# CACHE
# =====================================================

sysinfo_valkey_memory(){
    if command -v valkey-cli >/dev/null 2>&1; then
        valkey-cli info memory 2>/dev/null | grep used_memory_human | cut -d: -f2 | tr -d '[:space:]'
    else
        echo "N/A"
    fi
}

sysinfo_nginx_cache_active(){
    [ -d /var/cache/nginx ] && [ "$(find /var/cache/nginx -type f 2>/dev/null | head -n 1)" ]
}

sysinfo_http3_enabled(){
    nginx -V 2>&1 | grep -q http_v3_module
}

# =====================================================
# PHP
# =====================================================

sysinfo_php_opcache_enabled(){
    local php_bin="$1"
    command -v "$php_bin" &>/dev/null || return 1
    "$php_bin" -i 2>/dev/null | grep -q "opcache.enable => On"
}

sysinfo_php_jit_enabled(){
    local php_bin="$1"
    command -v "$php_bin" &>/dev/null || return 1
    "$php_bin" -i 2>/dev/null | grep -q "JIT => On"
}

# =====================================================
# DOMAINS
# =====================================================

sysinfo_domain_count(){
    find "$DOMAINS_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l
}

sysinfo_domain_count_by_type(){
    local type="$1"
    grep -rl "^APP_TYPE=${type}" "$DOMAINS_ROOT"/*/config/domain.env 2>/dev/null | wc -l
}

# =====================================================
# HOSTNAME / OS
# =====================================================

sysinfo_hostname(){
    hostname -f 2>/dev/null || hostname
}

sysinfo_os_name(){
    if [ -f /etc/os-release ]; then
        grep "^PRETTY_NAME=" /etc/os-release | cut -d'"' -f2
    else
        uname -sr
    fi
}

sysinfo_kernel(){
    uname -r
}

sysinfo_uptime(){
    uptime -p 2>/dev/null || uptime
}

# =====================================================
# AGGREGATE: collect all metrics into variables
# =====================================================

# Call this to populate all SYS_* variables in one shot.
# Useful for dashboards and monitoring.
collect_system_metrics(){
    SYS_CPU_LOAD=$(sysinfo_cpu_load)
    SYS_CPU_CORES=$(sysinfo_cpu_cores)
    SYS_RAM_TOTAL=$(sysinfo_ram_total_mb)
    SYS_RAM_USED=$(sysinfo_ram_used_mb)
    SYS_RAM_PERCENT=$(sysinfo_ram_percent)
    SYS_SWAP_TOTAL=$(sysinfo_swap_total_mb)
    SYS_SWAP_USED=$(sysinfo_swap_used_mb)
    SYS_DISK_PERCENT=$(sysinfo_disk_percent)
    SYS_DISK_USED=$(sysinfo_disk_used)
    SYS_DISK_TOTAL=$(sysinfo_disk_total)
    SYS_DOMAIN_COUNT=$(sysinfo_domain_count)
    SYS_OPEN_PORTS=$(sysinfo_open_port_count)
    SYS_NGINX_CONN=$(sysinfo_nginx_connections)
    SYS_VALKEY_MEM=$(sysinfo_valkey_memory)
    SYS_DB_PUBLIC=$(sysinfo_db_public)
}
