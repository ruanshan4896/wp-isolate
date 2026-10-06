#!/usr/bin/env python3
import glob
import os
import re
import subprocess
import sys

def detect_php():
    for p in ["/usr/bin/php", "/usr/local/bin/php", "/usr/local/lsws/lsphp81/bin/php", "/usr/local/lsws/lsphp80/bin/php", "/usr/local/lsws/lsphp74/bin/php"]:
        if os.path.exists(p) and os.access(p, os.X_OK):
            return p
    for p in glob.glob("/www/server/php/*/bin/php") + glob.glob("/usr/local/lsws/lsphp*/bin/lsphp"):
        if os.path.exists(p) and os.access(p, os.X_OK):
            return p
    return "php"

def clean_wp_config(content):
    lines = content.splitlines(keepends=True)
    new_lines = []
    i = 0
    while i < len(lines):
        line = lines[i]
        
        # 1. Tagged block removal
        if 'BEGIN WP-ISOLATE REDIS' in line:
            while i < len(lines) and 'END WP-ISOLATE REDIS' not in lines[i]:
                i += 1
            if i < len(lines) and 'END WP-ISOLATE REDIS' in lines[i]:
                i += 1
            continue

        # 2. if (!defined(...)) { ... } block removal
        if re.search(r'if\s*\(\s*!\s*defined\s*\([^\)]*(?:LITESPEED_CONF|WP_REDIS_|WP_CACHE_KEY_SALT)', line):
            depth = line.count('{') - line.count('}')
            i += 1
            while i < len(lines) and depth > 0:
                depth += lines[i].count('{') - lines[i].count('}')
                i += 1
            continue

        # 3. Standalone define statements
        if re.search(r'define\s*\(\s*[\'"](?:LITESPEED_CONF|WP_REDIS_|WP_CACHE_KEY_SALT)', line):
            i += 1
            continue

        # 4. Comments related to Redis or LiteSpeed Object Cache
        if any(marker in line for marker in [
            'LiteSpeed Cache (LSCWP) Native Object Cache Overrides',
            'Standard Redis Object Cache (Till',
            'WP-ISOLATE REDIS'
        ]):
            i += 1
            continue

        new_lines.append(line)
        i += 1

    res = ''.join(new_lines)
    res = re.sub(r'\n{3,}', '\n\n', res)
    return res

def main():
    print("=== WP-ISOLATE: PURGE REDIS & LITESPEED CACHE OVERRIDES ===")
    wp_configs = sorted(glob.glob("/www/wwwroot/*/wp-config.php"))
    if not wp_configs:
        print("No wp-config.php files found in /www/wwwroot/*/")
        return

    php_bin = detect_php()
    cleaned_count = 0

    for f in wp_configs:
        domain = os.path.basename(os.path.dirname(f))
        docroot = os.path.dirname(f)

        try:
            # Unlock immutable flag on file and directory
            subprocess.run(["chattr", "-i", f], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                os.chmod(f, 0o640)
            except Exception:
                pass

            with open(f, "r", encoding="utf-8", errors="ignore") as fp:
                original = fp.read()

            content = clean_wp_config(original)

            if content != original:
                # Write to temp file then atomic rename
                tmp_f = f + ".wp_isolate.tmp"
                try:
                    with open(tmp_f, "w", encoding="utf-8") as fp:
                        fp.write(content)
                    os.replace(tmp_f, f)
                except Exception:
                    with open(f, "w", encoding="utf-8") as fp:
                        fp.write(content)

                # Post-write verification
                with open(f, "r", encoding="utf-8", errors="ignore") as fp:
                    verify = fp.read()

                if "LITESPEED_CONF" in verify or "WP_REDIS_" in verify:
                    print(f"[WARN] Partial clean in {f} - attempting aggressive line filter...")
                    # Fallback line filter
                    aggressive_lines = [
                        l for l in verify.splitlines(keepends=True)
                        if not any(k in l for k in ["LITESPEED_CONF", "WP_REDIS_", "WP_CACHE_KEY_SALT"])
                    ]
                    with open(f, "w", encoding="utf-8") as fp:
                        fp.writelines(aggressive_lines)
                    print(f"[OK] Aggressively cleaned constants in: {f}")
                cleaned_count += 1

            # Restore isolated owner & write permissions so LiteSpeed Cache can modify WP_CACHE
            try:
                import pwd
                docroot_stat = os.stat(docroot)
                site_user = pwd.getpwuid(docroot_stat.st_uid).pw_name
                if not site_user.startswith("iso_") and site_user != "www":
                    clean_name = re.sub(r'[^a-z0-9]', '_', domain.lower())
                    clean_name = re.sub(r'_+', '_', clean_name).strip('_')
                    candidate = f"iso_{clean_name}"[:32]
                    try:
                        pwd.getpwnam(candidate)
                        site_user = candidate
                    except KeyError:
                        site_user = "www"
                if site_user:
                    u_info = pwd.getpwnam(site_user)
                    os.chown(f, u_info.pw_uid, u_info.pw_gid)
                    os.chmod(f, 0o664)
                    subprocess.run(["setfacl", "-m", "u:www:rw", f], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except Exception:
                try:
                    os.chmod(f, 0o664)
                except Exception:
                    pass

            # Remove object-cache.php and .litespeed_conf.dat drop-ins
            for dropin in ["object-cache.php", ".litespeed_conf.dat"]:
                dropin_path = os.path.join(docroot, "wp-content", dropin)
                if os.path.exists(dropin_path):
                    subprocess.run(["chattr", "-i", dropin_path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    try:
                        os.remove(dropin_path)
                        print(f"[OK] Removed dropin: {dropin_path}")
                    except Exception as e:
                        print(f"[WARN] Could not remove dropin {dropin_path}: {e}")

            # Reset LiteSpeed Cache & clean all corrupted transients across all sites
            wp_load = os.path.join(docroot, "wp-load.php")
            if os.path.isfile(wp_load):
                reset_php = f"""
define('WP_USE_THEMES', false);
@require_once '{wp_load}';
if (isset($GLOBALS['wpdb'])) {{
    $wpdb = $GLOBALS['wpdb'];
    $wpdb->query("DELETE FROM {{$wpdb->options}} WHERE option_name LIKE '%_transient_%'");
    if (function_exists('wp_clean_themes_cache')) {{
        wp_clean_themes_cache();
    }}
    if (function_exists('wp_clean_plugins_cache')) {{
        wp_clean_plugins_cache();
    }}
}}
if (function_exists('update_option')) {{
    update_option('litespeed.conf.cache-object', 0);
    update_option('litespeed.conf.cache-object-db_id', 0);
    update_option('litespeed.conf.cache-object-key_prefix', '');
    $conf = get_option('litespeed-conf');
    if (is_array($conf)) {{
        $conf['cache-object'] = 0;
        $conf['cache-object-db_id'] = 0;
        $conf['cache-object-key_prefix'] = '';
        update_option('litespeed-conf', $conf);
    }}
}}
"""
                try:
                    subprocess.run([php_bin, "-r", reset_php], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
                except Exception:
                    pass

        except Exception as e:
            print(f"[ERR] Failed to process {domain}: {e}")

    # Restart PHP workers and OpenLiteSpeed
    subprocess.run(["pkill", "-9", "-f", "lsphp"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if os.path.exists("/usr/local/lsws/bin/lswsctrl"):
        subprocess.run(["/usr/local/lsws/bin/lswsctrl", "restart"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    elif subprocess.run(["which", "systemctl"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        subprocess.run(["systemctl", "restart", "lsws"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    print(f"\nSuccessfully cleaned {cleaned_count} website(s) and restarted OpenLiteSpeed!")

if __name__ == "__main__":
    main()
