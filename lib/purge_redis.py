#!/usr/bin/env python3
import glob
import os
import re
import subprocess
import sys

def main():
    print("Purging legacy Redis and LiteSpeed Cache overrides from all websites...")
    wp_configs = glob.glob("/www/wwwroot/*/wp-config.php")
    if not wp_configs:
        print("No wp-config.php files found in /www/wwwroot/*/")
        return

    cleaned_count = 0
    for f in wp_configs:
        domain = os.path.basename(os.path.dirname(f))
        try:
            # Unlock immutable flag if set by aaPanel anti-tamper
            subprocess.run(["chattr", "-i", f], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                os.chmod(f, 0o640)
            except Exception:
                pass

            with open(f, "r", encoding="utf-8", errors="ignore") as fp:
                content = fp.read()

            original = content

            # 1. Remove tagged block
            content = re.sub(
                r'/\*\s*BEGIN WP-ISOLATE REDIS\s*\*.*?/\*\s*END WP-ISOLATE REDIS\s*\*/\r?\n?',
                '',
                content,
                flags=re.DOTALL
            )

            # 2. Remove 3-line if (!defined('...')) { define(...); } blocks
            content = re.sub(
                r'if\s*\(\s*!\s*defined\s*\([^\)]*(?:LITESPEED_CONF|WP_REDIS_|WP_CACHE_KEY_SALT)[^\)]*\)\s*\)\s*\{[^\}]*\}\r?\n?',
                '',
                content,
                flags=re.DOTALL
            )

            # 3. Remove standalone define statements
            content = re.sub(
                r'[ \t]*define\s*\(\s*[\'"](?:LITESPEED_CONF|WP_REDIS_|WP_CACHE_KEY_SALT)[^;]+;\r?\n?',
                '',
                content
            )

            # 4. Clean consecutive empty newlines
            content = re.sub(r'\n{3,}', '\n\n', content)

            if content != original:
                with open(f, "w", encoding="utf-8") as fp:
                    fp.write(content)
                print(f"[OK] Cleaned constants in: {f}")
                cleaned_count += 1

            # 5. Remove object cache drop-ins and dat configs
            docroot = os.path.dirname(f)
            for dropin in ["object-cache.php", ".litespeed_conf.dat"]:
                dropin_path = os.path.join(docroot, "wp-content", dropin)
                if os.path.exists(dropin_path):
                    try:
                        os.remove(dropin_path)
                        print(f"[OK] Removed dropin: {dropin_path}")
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
