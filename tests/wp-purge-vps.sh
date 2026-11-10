#!/bin/bash
# Disposable TEST.MD VPS only; repository must be at /tmp/sp-repo.
set -euo pipefail
DIR=${1:-ramfixtest_local}
DOM=${2:-ramfixtest.local}
ROOT=/home/domains/$DIR/public_html
CACHE=/var/cache/nginx/$DIR
FIXTURE=$ROOT/sp-purge-test.php
[ ! -e "$FIXTURE" ] || exit 1
cleanup(){ rm -f "$FIXTURE" "$ROOT/sp-purge-plugin.php" "$CACHE/sp-purge-sentinel"; }
trap cleanup EXIT
cp /tmp/sp-repo/shieldpress/templates/wp-mu-plugins/shieldpress-cache-purge.php "$ROOT/sp-purge-plugin.php"
cat > "$FIXTURE" <<'PHP'
<?php
function add_action(...$args) {}
function wp_cache_flush() {}
function wp_is_post_revision($id) {return false;}
function wp_is_post_autosave($id) {return false;}
function get_post($id) {return (object)['ID'=>$id, 'post_status'=>'publish'];}
define('ABSPATH', __DIR__.'/');
require __DIR__.'/sp-purge-plugin.php';
$p = new ShieldPress_Cache_Purge();
if (isset($_GET['post'])) {$p->purge_post(1);}
echo function_exists('exec') ? 'exec-enabled:' : 'exec-disabled:';
echo $p->purge();
PHP
chown "$DIR:$DIR" "$FIXTURE" "$ROOT/sp-purge-plugin.php"
for mode in manual post; do
    curl --fail -sS --resolve "$DOM:80:127.0.0.1" "http://$DOM/" >/dev/null
    curl --fail -sS -D /tmp/sp-purge-headers --resolve "$DOM:80:127.0.0.1" "http://$DOM/" >/dev/null
    grep -qi 'X-Cache: HIT' /tmp/sp-purge-headers
    echo sentinel > "$CACHE/sp-purge-sentinel"
    out=$(curl --fail -sS --resolve "$DOM:80:127.0.0.1" "http://$DOM/sp-purge-test.php?$mode=1")
    [ "$out" = exec-disabled:queued ]
    [ "$(cat "/home/domains/$DIR/tmp/.purge-cache")" = "$DIR" ]
    if [ "$mode" = manual ]; then
        echo 'Waiting for the actual cron worker (normally within one minute)...'
        for tick in {1..40}; do
            [ -e "$CACHE/sp-purge-sentinel" ] || break
            sleep 2
        done
    else
        /opt/shieldpress/bin/process-purge-signals
    fi
    [ ! -e "$CACHE/sp-purge-sentinel" ]
    [ ! -e "/home/domains/$DIR/tmp/.purge-cache" ]
    curl --fail -sS -D /tmp/sp-purge-headers --resolve "$DOM:80:127.0.0.1" "http://$DOM/" >/dev/null
    grep -qi 'X-Cache: MISS' /tmp/sp-purge-headers
    echo "PASS: real PHP-FPM $mode purge, disabled exec/open_basedir, worker removes cache"
done
