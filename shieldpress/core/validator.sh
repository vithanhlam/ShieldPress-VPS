#!/bin/bash
# =====================================================
# ShieldPress Core - Input Validator
# Source this file to get consistent validation functions.
# All validate_* functions return 0 on valid, 1 on invalid.
# All sanitize_* functions echo the cleaned value.
# =====================================================

# Validate domain name format (e.g. example.com, sub.example.co.uk)
validate_domain(){
    local domain="$1"
    [ -z "$domain" ] && return 1
    # Max 253 chars, labels 1-63 chars, alphanumeric + hyphens, no leading/trailing hyphens
    [[ "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] && return 0
    return 1
}

# Validate IPv4 address
validate_ipv4(){
    local ip="$1"
    [ -z "$ip" ] && return 1
    local IFS='.'
    local -a octets=($ip)
    [ ${#octets[@]} -ne 4 ] && return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
    done
    return 0
}

# Validate IPv6 address (basic check)
validate_ipv6(){
    local ip="$1"
    [ -z "$ip" ] && return 1
    [[ "$ip" =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$ ]] && return 0
    return 1
}

# Validate IP address (IPv4 or IPv6)
validate_ip(){
    validate_ipv4 "$1" || validate_ipv6 "$1"
}

# Validate port number (1-65535)
validate_port(){
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
    return 0
}

# Validate database name (alphanumeric + underscore, 1-64 chars)
validate_db_name(){
    local name="$1"
    [ -z "$name" ] && return 1
    [[ "$name" =~ ^[a-zA-Z][a-zA-Z0-9_]{0,63}$ ]] && return 0
    return 1
}

# Validate database user (alphanumeric + underscore, 1-32 chars)
validate_db_user(){
    local user="$1"
    [ -z "$user" ] && return 1
    [[ "$user" =~ ^[a-zA-Z][a-zA-Z0-9_]{0,31}$ ]] && return 0
    return 1
}

# Validate Linux username (alphanumeric + underscore + hyphen, 1-30 chars)
validate_username(){
    local user="$1"
    [ -z "$user" ] && return 1
    [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,29}$ ]] && return 0
    return 1
}

# Validate email address (basic)
validate_email(){
    local email="$1"
    [ -z "$email" ] && return 1
    [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] && return 0
    return 1
}

# Validate hour (0-23)
validate_hour(){
    local h="$1"
    [[ "$h" =~ ^[0-9]+$ ]] && [ "$h" -ge 0 ] && [ "$h" -le 23 ]
}

# Validate day of week (0-6)
validate_dow(){
    local d="$1"
    [[ "$d" =~ ^[0-6]$ ]]
}

# Validate day of month (1-28, safe for all months)
validate_dom(){
    local d="$1"
    [[ "$d" =~ ^[0-9]+$ ]] && [ "$d" -ge 1 ] && [ "$d" -le 28 ]
}

# Validate PHP version (e.g. 8.1, 8.2, 8.3, 8.4)
validate_php_version(){
    local ver="$1"
    [[ "$ver" =~ ^8\.[1-4]$ ]] && return 0
    return 1
}

# Validate file path (no null bytes, no ".." traversal, absolute path)
validate_path(){
    local path="$1"
    [ -z "$path" ] && return 1
    # Reject null bytes
    [[ "$path" == *$'\0'* ]] && return 1
    # Reject path traversal
    [[ "$path" == *".."* ]] && return 1
    # Must be absolute
    [[ "$path" == /* ]] && return 0
    return 1
}

# Validate URL (basic http/https)
validate_url(){
    local url="$1"
    [ -z "$url" ] && return 1
    [[ "$url" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?(/.*)?$ ]] && return 0
    return 1
}

# Validate yes/no input
validate_yes_no(){
    local input="$1"
    [[ "$input" =~ ^[yYnN]$ ]]
}

# Validate positive integer
validate_positive_int(){
    local val="$1"
    [[ "$val" =~ ^[1-9][0-9]*$ ]]
}

# =====================================================
# SANITIZERS - clean input for safe use
# =====================================================

# Sanitize string for use as database name / folder name
sanitize_identifier(){
    echo "$1" | sed 's/[^a-zA-Z0-9]/_/g' | cut -c1-30
}

# Sanitize domain → clean folder name (consistent with clean_domain_name)
sanitize_domain_folder(){
    echo "$1" | sed 's/[^a-zA-Z0-9]/_/g' | cut -c1-30
}

# Sanitize string for safe use in SQL single-quoted values
# Escapes single quotes by doubling them
sanitize_sql(){
    echo "$1" | sed "s/'/''/g"
}

# Sanitize string for safe use in log files (remove control chars)
sanitize_log(){
    echo "$1" | tr -d '\000-\011\013-\037'
}

# Sanitize filename (allow alphanumeric, dots, hyphens, underscores)
sanitize_filename(){
    echo "$1" | sed 's/[^a-zA-Z0-9._-]/_/g'
}

# =====================================================
# INTERACTIVE HELPERS - ask + validate in one step
# =====================================================

# Ask for a value with validation, retrying on failure.
# Usage: ask_validated VARNAME "prompt" validate_function [default]
ask_validated(){
    local -n _result=$1
    local prompt="$2"
    local validator="$3"
    local default="$4"

    while true; do
        if [ -n "$default" ]; then
            read -p "$prompt [$default]: " _result
            [ -z "$_result" ] && _result="$default"
        else
            read -p "$prompt: " _result
        fi
        if $validator "$_result"; then
            return 0
        fi
        echo "Invalid input. Please try again."
    done
}
