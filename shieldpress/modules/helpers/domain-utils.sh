#!/bin/bash

# =====================================================
# DOMAIN UTILS - ShieldPress
# =====================================================

domain_to_clean(){

local DOMAIN="$1"

# convert domain → folder name
# zvps.net → zvps_net
# my-site.com → my_site_com

echo "$DOMAIN" | sed 's/[^a-zA-Z0-9]/_/g' | cut -c1-30

}

domain_to_user(){

local DOMAIN="$1"

echo "$DOMAIN" | sed 's/[^a-zA-Z0-9]/_/g' | cut -c1-30

}

domain_to_nginx(){

local DOMAIN="$1"

CLEAN=$(domain_to_clean "$DOMAIN")

echo "/etc/nginx/conf.d/${CLEAN}.conf"

}

domain_to_path(){

local DOMAIN="$1"

CLEAN=$(domain_to_clean "$DOMAIN")

echo "/home/domains/${CLEAN}"

}

domain_to_db(){

local DOMAIN="$1"

CLEAN=$(domain_to_clean "$DOMAIN")

echo "${CLEAN}_db"

}