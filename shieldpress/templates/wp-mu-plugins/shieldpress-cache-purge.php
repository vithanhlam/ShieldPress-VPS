<?php
/**
 * Plugin Name: ShieldPress Auto Cache Purge
 * Description: Automatically purges Nginx FastCGI cache when content changes.
 * Version: 1.0
 * Author: ShieldPress
 */

if ( ! defined( 'ABSPATH' ) ) {
    exit;
}

class ShieldPress_Cache_Purge {

    private $cache_dir;
    private $purge_script;
    private $purged = false;

    public function __construct() {
        $clean = preg_replace( '/[^a-zA-Z0-9]/', '_', $_SERVER['HTTP_HOST'] ?? '' );
        $this->cache_dir    = '/var/cache/nginx/' . $clean;
        $this->purge_script = '/opt/shieldpress/bin/purge-fastcgi-cache';

        // Post/Page create, update, delete, trash (smart purge per post)
        add_action( 'save_post',           [ $this, 'purge_post' ] );
        add_action( 'deleted_post',        [ $this, 'purge' ] );
        add_action( 'trashed_post',        [ $this, 'purge_post' ] );
        add_action( 'untrashed_post',      [ $this, 'purge_post' ] );

        // Comments
        add_action( 'comment_post',        [ $this, 'purge' ] );
        add_action( 'edit_comment',        [ $this, 'purge' ] );
        add_action( 'wp_set_comment_status', [ $this, 'purge' ] );

        // Terms (categories, tags)
        add_action( 'created_term',        [ $this, 'purge' ] );
        add_action( 'edited_term',         [ $this, 'purge' ] );
        add_action( 'delete_term',         [ $this, 'purge' ] );

        // Theme switch
        add_action( 'switch_theme',        [ $this, 'purge' ] );

        // Plugin/Theme install, update, activate, deactivate
        add_action( 'activated_plugin',    [ $this, 'purge' ] );
        add_action( 'deactivated_plugin',  [ $this, 'purge' ] );
        add_action( 'upgrader_process_complete', [ $this, 'purge' ] );

        // Core update
        add_action( '_core_updated_successfully', [ $this, 'purge' ] );

        // Translation update
        add_action( 'update_option_WPLANG', [ $this, 'purge' ] );

        // Permalink structure change
        add_action( 'update_option_permalink_structure', [ $this, 'purge' ] );

        // Widget update
        add_action( 'update_option_sidebars_widgets', [ $this, 'purge' ] );

        // Menu update
        add_action( 'wp_update_nav_menu',  [ $this, 'purge' ] );

        // Customizer save
        add_action( 'customize_save_after', [ $this, 'purge' ] );

        // WooCommerce
        add_action( 'woocommerce_product_set_stock',       [ $this, 'purge' ] );
        add_action( 'woocommerce_variation_set_stock',     [ $this, 'purge' ] );
        add_action( 'woocommerce_product_set_stock_status', [ $this, 'purge' ] );

        // User profile update (author pages)
        add_action( 'profile_update',      [ $this, 'purge' ] );

        // Attachment (media library changes)
        add_action( 'add_attachment',      [ $this, 'purge' ] );
        add_action( 'edit_attachment',     [ $this, 'purge' ] );
        add_action( 'delete_attachment',   [ $this, 'purge' ] );

        // Admin bar: manual purge button
        add_action( 'admin_bar_menu',      [ $this, 'admin_bar_button' ], 100 );
        add_action( 'admin_post_shieldpress_purge', [ $this, 'handle_manual_purge' ] );
        add_action( 'admin_notices',       [ $this, 'show_purge_notice' ] );
    }

    /**
     * Purge entire FastCGI cache for this domain.
     *
     * Strategy (in order):
     * 1. exec() sudo purge script — fast, but exec is often disabled
     * 2. File signal — PHP writes a trigger file, cron/systemd picks it up
     *    and runs the purge as root within seconds. Always works.
     *
     * @return string 'ok' | 'fail'
     */
    public function purge() {
        if ( $this->purged ) {
            return 'ok';
        }

        $clean   = basename( $this->cache_dir );
        $success = false;

        // Method 1: exec sudo purge script (fastest, but exec often disabled)
        if ( function_exists( 'exec' ) ) {
            $output = [];
            $code   = 1;
            @exec( "sudo {$this->purge_script} " . escapeshellarg( $clean ) . " 2>&1", $output, $code );
            if ( $code === 0 ) {
                $success = true;
            }
        }

        // Method 2: file signal (works with exec disabled + open_basedir + PrivateTmp)
        // Write signal to domain's own tmp dir (always accessible by PHP)
        // Cron scans /home/domains/*/tmp/.purge-cache and runs purge as root
        if ( ! $success ) {
            $domain_root = defined( 'ABSPATH' ) ? ABSPATH : ( $_SERVER['DOCUMENT_ROOT'] ?? '' );
            $signal_dir  = dirname( $domain_root ) . '/tmp';
            $signal_file = $signal_dir . '/.purge-cache';

            if ( is_dir( $signal_dir ) ) {
                @file_put_contents( $signal_file, $clean );
                if ( @file_exists( $signal_file ) ) {
                    $success = true;
                }
            }
        }

        $this->purged = $success;

        // Always flush WP object cache
        if ( function_exists( 'wp_cache_flush' ) ) {
            wp_cache_flush();
        }

        return $success ? 'ok' : 'fail';
    }

    /**
     * Smart purge: only clear cache for a specific post and its related pages.
     * Falls back to full purge if URL-based purge is not possible.
     */
    public function purge_post( $post_id ) {
        if ( $this->purged || wp_is_post_revision( $post_id ) || wp_is_post_autosave( $post_id ) ) {
            return;
        }

        $post = get_post( $post_id );
        if ( ! $post || $post->post_status !== 'publish' ) {
            return;
        }

        // Collect URLs to purge
        $urls = [];
        $urls[] = get_permalink( $post_id );
        $urls[] = home_url( '/' );

        // Category/tag archive pages
        $categories = get_the_category( $post_id );
        if ( $categories ) {
            foreach ( $categories as $cat ) {
                $urls[] = get_category_link( $cat->term_id );
            }
        }
        $tags = get_the_tags( $post_id );
        if ( $tags ) {
            foreach ( $tags as $tag ) {
                $urls[] = get_tag_link( $tag->term_id );
            }
        }

        // Author archive
        $urls[] = get_author_posts_url( $post->post_author );

        // Purge each URL's cache file using Nginx cache key hash
        foreach ( $urls as $url ) {
            if ( $url ) {
                $this->purge_url( $url );
            }
        }

        // Also flush WP object cache
        if ( function_exists( 'wp_cache_flush' ) ) {
            wp_cache_flush();
        }
    }

    /**
     * Purge a single URL from FastCGI cache by computing its cache key hash.
     * Nginx default cache key: $scheme$request_method$host$request_uri
     */
    private function purge_url( $url ) {
        $parsed = parse_url( $url );
        if ( ! $parsed || empty( $parsed['host'] ) ) {
            return;
        }

        $scheme = $parsed['scheme'] ?? 'https';
        $host   = $parsed['host'];
        $uri    = $parsed['path'] ?? '/';
        if ( ! empty( $parsed['query'] ) ) {
            $uri .= '?' . $parsed['query'];
        }

        // Nginx cache key format (must match your fastcgi_cache_key)
        $cache_key  = $scheme . 'GET' . $host . $uri;
        $md5        = md5( $cache_key );

        // Nginx stores cache in: $cache_dir / last_char / second_to_last_two / md5
        $cache_path = $this->cache_dir . '/' . substr( $md5, -1 ) . '/' . substr( $md5, -3, 2 ) . '/' . $md5;

        if ( file_exists( $cache_path ) ) {
            @unlink( $cache_path );
        }
    }

    /**
     * Add "Purge Cache" button to admin bar.
     */
    public function admin_bar_button( $wp_admin_bar ) {
        if ( ! current_user_can( 'manage_options' ) ) {
            return;
        }

        $wp_admin_bar->add_node( [
            'id'    => 'shieldpress-purge-cache',
            'title' => '<span class="ab-icon dashicons dashicons-update" style="margin-top:2px"></span><span class="ab-label">Purge Cache</span>',
            'href'  => wp_nonce_url( admin_url( 'admin-post.php?action=shieldpress_purge' ), 'shieldpress_purge' ),
        ] );
    }

    /**
     * Handle manual purge from admin bar.
     */
    public function handle_manual_purge() {
        if ( empty( $_REQUEST['action'] ) || $_REQUEST['action'] !== 'shieldpress_purge' ) {
            return;
        }

        if ( ! current_user_can( 'manage_options' ) || ! wp_verify_nonce( $_GET['_wpnonce'] ?? '', 'shieldpress_purge' ) ) {
            wp_die( 'Unauthorized', 403 );
        }

        $result = $this->purge(); // 'ok' | 'empty' | 'fail'

        $redirect = wp_get_referer();
        if ( ! $redirect ) {
            $redirect = admin_url();
        }
        wp_safe_redirect( add_query_arg( 'shieldpress_purged', $result, $redirect ) );
        exit;
    }

    /**
     * Show success/failure notice after purge redirect.
     */
    public function show_purge_notice() {
        if ( empty( $_GET['shieldpress_purged'] ) ) {
            return;
        }

        if ( $_GET['shieldpress_purged'] === 'ok' ) {
            echo '<div class="notice notice-success is-dismissible"><p><strong>ShieldPress:</strong> Cache purged successfully.</p></div>';
        } else {
            echo '<div class="notice notice-error is-dismissible"><p><strong>ShieldPress:</strong> Failed to purge FastCGI cache. Run <code>shieldpress &gt; Cache &gt; Auto Purge</code> to fix permissions.</p></div>';
        }
    }
}

new ShieldPress_Cache_Purge();
