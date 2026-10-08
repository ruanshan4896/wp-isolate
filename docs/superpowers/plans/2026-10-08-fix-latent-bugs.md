# Implementation Plan: Fix Latent Bugs and Edge Cases in `wp-isolate`

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve 11 identified latent bugs and architectural edge cases across `bin/wp-isolate`, `bin/wp-isolate-sentinel`, `lib/ols_vhost.sh`, `lib/os_user.sh`, `lib/mysql_limit.sh`, and `lib/fix_all.py`.

**Architecture:** Maintain strict aaPanel zero-conflict, pure 4-layer isolation, and POSIX ACL boundaries. Fix false `DEFAULT` status reporting, repair broken `verify` audit logic, ensure graceful OLS reloads without dropping connections, protect MySQL administrative users (`root`), prevent Sentinel fast-retry CPU storms, and eliminate Wordfence WAF false positives.

**Tech Stack:** Bash, Python 3, OpenLiteSpeed API/CLI, MySQL/MariaDB, POSIX ACL.

**Spec Reference:** [docs/superpowers/specs/2026-10-06-pure-isolation-redis-decoupling-design.md](file:///c:/Users/aaaa/Desktop/wp-isolate/docs/superpowers/specs/2026-10-06-pure-isolation-redis-decoupling-design.md) & [docs/superpowers/specs/2026-10-04-zero-touch-auto-isolation-design.md](file:///c:/Users/aaaa/Desktop/wp-isolate/docs/superpowers/specs/2026-10-04-zero-touch-auto-isolation-design.md)

## Global Constraints
- Preserve zero-conflict with aaPanel web interface.
- Zero-downtime graceful reload priority (never hard restart OLS when graceful reload is available).
- Never throttle or limit administrative MySQL accounts (`root`, `debian-sys-maint`).
- All tests in `tests/` must pass 100%.

---

### Task 1: Fix `cmd_status`, `cmd_verify`, and `cmd_repair` in `bin/wp-isolate`

**Files:**
- Modify: `bin/wp-isolate`
- Test: `tests/test_cli_workflow.sh`

- [x] **Step 1: Write failing test in `tests/test_cli_workflow.sh`**
  Add assertions for:
  - `status` reporting `ISOLATED` for an isolated site.
  - `verify` detecting missing isolation configurations when drift occurs.
- [x] **Step 2: Run test to verify failure**
- [x] **Step 3: Implement fixes in `bin/wp-isolate`**
  - Update `cmd_status` to check `detail_file` (`extUser iso_` or `WP-ISOLATE`) and `outer_file` (`setUIDMode 2`).
  - Update `cmd_verify` to audit sites from `sites.json` and aaPanel vhost files instead of empty `$VHOSTS_DIR`.
  - Update `cmd_repair` to use `detect_vhost_docroot`, ensure `create_isolated_user`, and pass `$user` to `verify_and_reload_ols` for single-site repair.
- [x] **Step 4: Run test to verify pass**

---

### Task 2: Fix Graceful Reload & Socket Cleanup in `lib/ols_vhost.sh` and `bin/wp-isolate`

**Files:**
- Modify: `lib/ols_vhost.sh`
- Modify: `bin/wp-isolate`
- Test: `tests/test_ols_vhost.sh`

- [x] **Step 1: Update `verify_and_reload_ols` in `lib/ols_vhost.sh`**
  - Prioritize `lswsctrl reload` or `systemctl reload lsws` before falling back to `restart`.
  - Ensure `/tmp/lshttpd` is created with mode 1777 if missing.
- [x] **Step 2: Update `clean_single_domain` in `bin/wp-isolate`**
  - Remove both `*${target_domain}*` and `*${clean_domain}*` socket files.
- [x] **Step 3: Run `tests/test_ols_vhost.sh` and `tests/test_cli_workflow.sh`**

---

### Task 3: Protect MySQL Administrative Users in `lib/mysql_limit.sh`

**Files:**
- Modify: `lib/mysql_limit.sh`
- Test: `tests/test_mysql_limit.sh`

- [x] **Step 1: Add unit tests in `tests/test_mysql_limit.sh`**
  - Test that `set_mysql_user_limit "root"` and `remove_mysql_user_limit "root"` safely return 0 without executing `ALTER USER`.
- [x] **Step 2: Implement guard in `lib/mysql_limit.sh`**
- [x] **Step 3: Run `tests/test_mysql_limit.sh`**

---

### Task 4: Fix Sentinel Handshake, Fast-Retry Loop, Port Extraction & Scanner

**Files:**
- Modify: `bin/wp-isolate-sentinel`
- Modify: `bin/wp-isolate` (scan function)

- [x] **Step 1: Update Handshake in `is_aapanel_site_ready`**
  - Check that `detail/<domain>.conf` exists and contains `extprocessor`.
- [x] **Step 2: Add failure cooldown in Sentinel auto-isolation**
  - Prevent 5-second rapid spin on failed isolation; wait 60s before retry.
- [x] **Step 3: Strip port in 503 log extraction**
  - `domain="${domain%:*}"`
- [x] **Step 4: Fix scanner and sanitizer**
  - Include `.phtml`, `.php[0-9]`, `.phps`.
  - Do not delete legitimate WAF auto_prepend directives (e.g. Wordfence).
  - Run sanitizer immediately on startup, then sleep 600.

---

### Task 5: Fix Immutable Permissions in `lib/os_user.sh` & Username Sanitization in `lib/fix_all.py`

**Files:**
- Modify: `lib/os_user.sh`
- Modify: `lib/fix_all.py`
- Test: `tests/test_os_user.sh`

- [x] **Step 1: Add `chattr -i` handling before modifying `wp-config.php` in `lib/os_user.sh`**
- [x] **Step 2: Update `fix_all.py` username sanitization to match `common.sh`**
- [x] **Step 3: Run `tests/test_os_user.sh`**

---

### Task 6: Full Verification Sweep

- [x] **Run `bash tests/run_all_tests.sh` and verify all tests pass 100%**
