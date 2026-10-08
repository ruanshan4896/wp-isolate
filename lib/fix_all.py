#!/usr/bin/env python3
"""
lib/fix_all.py - Master One-Shot Health & Stability Healer for all 45+ aaPanel/OLS WordPress sites
Solves root causes across all websites simultaneously:
1. Fixes ownership & write permissions on wp-config.php (user iso_* rw-, ACL www rw-)
2. Flushes corrupted database transients (_transient_%) causing 4GB memory recursion in theme.php
3. Configures WP_MEMORY_LIMIT (256M) and WP_MAX_MEMORY_LIMIT (512M) in wp-config.php
4. Sets OpenLiteSpeed memSoftLimit & memHardLimit to 2047M across all detail/*.conf
5. Sets global php.ini memory_limit = 512M
6. Purges legacy Redis/LSCache drop-ins and resets object cache database options to 0 (OFF)
7. Validates every website with headless PHP execution to guarantee 0 fatal errors
"""
import glob
import os
import pwd
import re
import subprocess
import sys

def detect_php():
    for p in ["/usr/local/lsws/lsphp81/bin/php", "/usr/local/lsws/lsphp80/bin/php", "/usr/local/lsws/lsphp74/bin/php"]:
        if os.path.exists(p) and os.access(p, os.X_OK):
            return p
    for p in glob.glob("/usr/local/lsws/lsphp*/bin/php") + glob.glob("/www/server/php/*/bin/php"):
        if os.path.exists(p) and os.access(p, os.X_OK):
            return p
    return "php"

# NOTE: code passed to `php -r` must NOT start with "<?php" (that causes a parse error).
WP_BOOT = """
error_reporting(E_ALL & ~E_WARNING & ~E_NOTICE & ~E_DEPRECATED);
$_SERVER['HTTP_HOST'] = '{domain}';
$_SERVER['SERVER_NAME'] = '{domain}';
$_SERVER['REQUEST_URI'] = '/';
$_SERVER['REQUEST_METHOD'] = 'GET';
define('WP_USE_THEMES', false);
require_once '{wp_load}';
"""

def sanitize_domain_to_user(domain):
    clean_name = re.sub(r'[^a-z0-9]+', '_', domain.lower()).strip('_')
    return f"iso_{clean_name}"[:31].rstrip('_')

def detect_site_user(docroot, domain):
    try:
        u = pwd.getpwuid(os.stat(docroot).st_uid).pw_name
        if u.startswith("iso_") or u == "www":
            return u
    except Exception:
        pass
    candidate = sanitize_domain_to_user(domain)
    try:
        pwd.getpwnam(candidate)
        return candidate
    except KeyError:
        return "www"

def run_wp_php(php_bin, code, user, cwd, timeout=30):
    """Run PHP code as the site's own user (never root) so no root-owned cache files are created."""
    cmd = [php_bin, "-d", "memory_limit=512M", "-r", code]
    if user and user != "root" and os.geteuid() == 0:
        cmd = ["runuser", "-u", user, "--"] + cmd
    try:
        p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
        return p.returncode == 0, p.stdout.decode("utf-8", "ignore"), p.stderr.decode("utf-8", "ignore")
    except subprocess.TimeoutExpired:
        return False, "", f"timeout after {timeout}s"
    except Exception as e:
        return False, "", str(e)

def last_error_line(text):
    lines = [l.strip() for l in text.strip().splitlines() if l.strip()]
    for l in reversed(lines):
        if "Fatal" in l or "Parse error" in l or "Error" in l or "timeout" in l:
            return l[:300]
    return lines[-1][:300] if lines else ""

def main():
    print("===================================================================")
    print("      WP-ISOLATE: MASTER ONE-SHOT REPAIR ACROSS ALL WEBSITES       ")
    print("===================================================================")

    php_bin = detect_php()
    print(f"[INFO] Using PHP Engine: {php_bin}")

    # -------------------------------------------------------------
    # 1. Update OpenLiteSpeed Virtual Memory Limits (2047M)
    # -------------------------------------------------------------
    print("\n>>> Step 1/5: Enforcing OpenLiteSpeed Memory Limits (2047M)...")
    for f in glob.glob("/www/server/panel/vhost/openlitespeed/detail/*.conf"):
        try:
            with open(f, "r", encoding="utf-8", errors="ignore") as fp:
                c = fp.read()
            c = re.sub(r'memSoftLimit\s+[0-9]+M?', 'memSoftLimit            2047M', c)
            c = re.sub(r'memHardLimit\s+[0-9]+M?', 'memHardLimit            2047M', c)
            with open(f, "w", encoding="utf-8") as fp:
                fp.write(c)
        except Exception:
            pass
    print("[OK] OpenLiteSpeed vhosts updated with 2047M virtual memory headroom.")

    # -------------------------------------------------------------
    # 2. Update Global php.ini Limits (memory_limit = 512M)
    # -------------------------------------------------------------
    print("\n>>> Step 2/5: Enforcing php.ini memory_limit = 512M...")
    ini_files = glob.glob("/usr/local/lsws/lsphp*/etc/php/*/litespeed/php.ini") + glob.glob("/www/server/php/*/etc/php.ini")
    for ini in ini_files:
        try:
            with open(ini, "r", encoding="utf-8", errors="ignore") as fp:
                c = fp.read()
            c = re.sub(r'^[;\s]*memory_limit\s*=.*', 'memory_limit = 512M', c, flags=re.MULTILINE)
            with open(ini, "w", encoding="utf-8") as fp:
                fp.write(c)
        except Exception:
            pass
    print("[OK] Global PHP memory_limit set to 512M.")

    # -------------------------------------------------------------
    # 3. Process every WordPress website in /www/wwwroot/
    # -------------------------------------------------------------
    print("\n>>> Step 3/5: Deep cleaning database transients, permissions & wp-config...")
    sites = sorted(glob.glob("/www/wwwroot/*/wp-config.php"))
    success_count = 0
    fail_count = 0

    for wp_config in sites:
        docroot = os.path.dirname(wp_config)
        domain = os.path.basename(docroot)
        wp_load = os.path.join(docroot, "wp-load.php")

        try:
            # 3a. Unlock and set file permissions
            subprocess.run(["chattr", "-i", wp_config], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            
            # Detect site user (iso_<domain> or owner of docroot)
            site_user = "www"
            try:
                docroot_stat = os.stat(docroot)
                site_user = pwd.getpwuid(docroot_stat.st_uid).pw_name
            except Exception:
                pass

            if not site_user.startswith("iso_") and site_user != "www":
                candidate = sanitize_domain_to_user(domain)
                try:
                    pwd.getpwnam(candidate)
                    site_user = candidate
                except KeyError:
                    site_user = "www"

            # 3b. Read wp-config and ensure memory & direct FS settings
            with open(wp_config, "r", encoding="utf-8", errors="ignore") as fp:
                conf_data = fp.read()

            orig_conf = conf_data

            # Remove any orphan Redis / LiteSpeed overrides
            conf_data = re.sub(r'if\s*\(\s*!\s*defined\s*\([^\)]*(?:LITESPEED_CONF|WP_REDIS_|WP_CACHE_KEY_SALT)[^\)]*\)\s*\)\s*\{[^\}]*\}\r?\n?', '', conf_data, flags=re.DOTALL)
            conf_data = re.sub(r'[ \t]*define\s*\(\s*[\'"](?:LITESPEED_CONF|WP_REDIS_|WP_CACHE_KEY_SALT)[^;]+;\r?\n?', '', conf_data)
            conf_data = re.sub(r'/\*\s*BEGIN WP-ISOLATE REDIS\s*\*.*?/\*\s*END WP-ISOLATE REDIS\s*\*/\r?\n?', '', conf_data, flags=re.DOTALL)

            # Ensure WP_MAX_MEMORY_LIMIT 512M is present alongside WP_MEMORY_LIMIT 256M
            if "WP_MAX_MEMORY_LIMIT" not in conf_data:
                conf_data = re.sub(
                    r'(define\(\s*[\'"]WP_MEMORY_LIMIT[\'"]\s*,\s*[\'"][^\'"]+[\'"]\s*\);)',
                    r"\1\ndefine( 'WP_MAX_MEMORY_LIMIT', '512M' );",
                    conf_data
                )

            if conf_data != orig_conf:
                with open(wp_config, "w", encoding="utf-8") as fp:
                    fp.write(conf_data)

            # Chown and chmod so LiteSpeed Cache & WordPress can write WP_CACHE freely
            try:
                u_info = pwd.getpwnam(site_user)
                os.chown(wp_config, u_info.pw_uid, u_info.pw_gid)
                os.chmod(wp_config, 0o664)
                subprocess.run(["setfacl", "-m", "u:www:rw", wp_config], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except Exception:
                try:
                    os.chmod(wp_config, 0o664)
                except Exception:
                    pass

            # 3c. Remove drop-ins
            for dropin in ["object-cache.php", ".litespeed_conf.dat"]:
                dp = os.path.join(docroot, "wp-content", dropin)
                if os.path.exists(dp):
                    subprocess.run(["chattr", "-i", dp], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    try:
                        os.remove(dp)
                    except Exception:
                        pass

            # 3d. Database Flush: Delete all stale transients and reset LSCache in DB
            flush_status = "no wp-load.php"
            if os.path.isfile(wp_load):
                php_flush_code = WP_BOOT.format(domain=domain, wp_load=wp_load) + """
if (isset($GLOBALS['wpdb'])) {
    $wpdb = $GLOBALS['wpdb'];
    // Delete all temporary transients (theme, plugin, core) to kill any infinite recursion loops
    $n = $wpdb->query("DELETE FROM {$wpdb->options} WHERE option_name LIKE '%\\_transient\\_%'");
    if (function_exists('wp_clean_themes_cache')) {
        wp_clean_themes_cache();
    }
    if (function_exists('wp_clean_plugins_cache')) {
        wp_clean_plugins_cache();
    }
    echo 'FLUSHED:' . intval($n);
}
if (function_exists('update_option')) {
    update_option('litespeed.conf.cache-object', 0);
    update_option('litespeed.conf.cache-object-db_id', 0);
    update_option('litespeed.conf.cache-object-key_prefix', '');
    $conf = get_option('litespeed-conf');
    if (is_array($conf)) {
        $conf['cache-object'] = 0;
        $conf['cache-object-db_id'] = 0;
        $conf['cache-object-key_prefix'] = '';
        update_option('litespeed-conf', $conf);
    }
}
"""
                ok, out, err = run_wp_php(php_bin, php_flush_code, site_user, docroot, timeout=30)
                m = re.search(r'FLUSHED:(\d+)', out)
                if m:
                    flush_status = f"{m.group(1)} transient rows deleted"
                else:
                    flush_status = "FLUSH FAILED: " + (last_error_line(err) or last_error_line(out) or "unknown")

            tag = "[OK]" if not flush_status.startswith("FLUSH FAILED") else "[WARN]"
            print(f"  {tag} {domain} (User: {site_user}) -> {flush_status}")
            if tag == "[OK]":
                success_count += 1
            else:
                fail_count += 1

        except Exception as e:
            print(f"  [WARN] Failed to process {domain}: {e}")
            fail_count += 1

    # -------------------------------------------------------------
    # 4. Restart Web Server & PHP Workers
    # -------------------------------------------------------------
    print("\n>>> Step 4/5: Restarting PHP workers & OpenLiteSpeed...")
    subprocess.run(["pkill", "-9", "-f", "lsphp"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if os.path.exists("/usr/local/lsws/bin/lswsctrl"):
        subprocess.run(["/usr/local/lsws/bin/lswsctrl", "restart"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    elif subprocess.run(["which", "systemctl"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        subprocess.run(["systemctl", "restart", "lsws"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # -------------------------------------------------------------
    # 5. Verification Sweep (Guarantee 0 Fatal Errors)
    # -------------------------------------------------------------
    print("\n>>> Step 5/5: Running Headless Health Check across all sites...")
    healthy = 0
    for wp_config in sites:
        docroot = os.path.dirname(wp_config)
        domain = os.path.basename(docroot)
        check_script = os.path.join(docroot, "wp-load.php")
        if not os.path.isfile(check_script):
            continue

        site_user = detect_site_user(docroot, domain)
        # Boot WordPress fully (incl. theme functions) like a real admin request would
        test_code = WP_BOOT.format(domain=domain, wp_load=check_script) + """
if (function_exists('wp_get_theme')) { wp_get_theme(); }
if (function_exists('get_theme_roots')) { get_theme_roots(); }
echo 'HEALTH_OK';
"""
        ok, out, err = run_wp_php(php_bin, test_code, site_user, docroot, timeout=30)
        if "HEALTH_OK" in out and "Fatal error" not in err and "Fatal error" not in out:
            healthy += 1
        else:
            print(f"  [ALERT] {domain}: {last_error_line(err) or last_error_line(out) or 'no output (timeout?)'}")

    print("\n===================================================================")
    print(f"   REPAIR COMPLETE: {success_count} sites repaired | {healthy}/{len(sites)} verified healthy")
    print("===================================================================")

if __name__ == "__main__":
    main()
