<?php
/**
 * Plugin Name: ShieldPress Auto Cache Purge
 * Description: Automatically purges Nginx FastCGI cache when content changes.
 * Version: 1.1
 * Author: ShieldPress
 */

if ( ! defined( 'ABSPATH' ) ) {
    exit;
}

class ShieldPress_Cache_Purge {

    private $cache_dir;
    private $purged = false;

    public function __construct() {
        // Use the managed directory identity, independent of URL aliases or Host.
        $clean = basename( dirname( rtrim( ABSPATH, '/\\' ) ) );
        $this->cache_dir    = '/var/cache/nginx/' . $clean;

        // Post/Page create, update, delete, trash
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
     * PHP writes a bounded domain signal. A root-owned worker clears only
     * the originating domain's cache; PHP receives no sudo capability.
     *
     * @return string 'ok' | 'queued' | 'fail'
     */
    public function purge() {
        if ( $this->purged ) {
            return $this->purged;
        }

        $clean   = basename( $this->cache_dir );
        $success = false;

        // The signal directory is within this site's open_basedir.
        if ( ! $success ) {
            $domain_root = defined( 'ABSPATH' ) ? ABSPATH : ( $_SERVER['DOCUMENT_ROOT'] ?? '' );
            $signal_dir  = dirname( rtrim( $domain_root, '/\\' ) ) . '/tmp';
            $signal_file = $signal_dir . '/.purge-cache';

            if ( is_dir( $signal_dir ) ) {
                if ( ! is_link( $signal_file ) && @file_put_contents( $signal_file, $clean, LOCK_EX ) === strlen( $clean ) ) {
                    $success = 'queued';
                }
            }
        }

        $this->purged = $success;

        // Always flush WP object cache
        if ( function_exists( 'wp_cache_flush' ) ) {
            wp_cache_flush();
        }

        return $success ? $success : 'fail';
    }

    /**
     * Invalidate the domain when a post changes, including unpublishing.
     */
    public function purge_post( $post_id ) {
        if ( $this->purged || wp_is_post_revision( $post_id ) || wp_is_post_autosave( $post_id ) ) {
            return;
        }

        $post = get_post( $post_id );
        if ( ! $post || empty( $post->ID ) ) {
            return;
        }

        // PHP cannot unlink Nginx cache under open_basedir. Queue a domain purge
        // through the same privileged consumer used by the manual button.
        $this->purge();
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

        $result = $this->purge(); // 'ok' | 'queued' | 'fail'

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
        } elseif ( $_GET['shieldpress_purged'] === 'queued' ) {
            echo '<div class="notice notice-info is-dismissible"><p><strong>ShieldPress:</strong> Cache purge queued. The background worker normally clears FastCGI cache within one minute.</p></div>';
        } else {
            echo '<div class="notice notice-error is-dismissible"><p><strong>ShieldPress:</strong> Failed to purge FastCGI cache. Run <code>shieldpress &gt; Cache &gt; Auto Purge</code> to fix permissions.</p></div>';
        }
    }
}

new ShieldPress_Cache_Purge();
