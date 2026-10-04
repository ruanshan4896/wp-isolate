# Zero-Touch Auto-Isolation & Anti-Malware Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade `wp-isolate` to v2.0 with Granular POSIX ACLs, OLS uploads PHP blocking, and a zero-touch Sentinel daemon with 15s debounce and handshake verification to prevent race conditions with aaPanel.

**Architecture:** 
1. Upgrade `lib/os_user.sh` to enforce Granular POSIX ACLs (`rx` for docroot/core, `0` or `r` for `wp-config.php`, `rwx` strictly for `wp-content/uploads/`).
2. Upgrade `lib/ols_vhost.sh` to inject OpenLiteSpeed native rewrite rules blocking direct execution of `*.php` in `wp-content/uploads/`.
3. Create `bin/wp-isolate-sentinel` daemon (unifying auto-isolation with 15s debounce + aaPanel handshake verification, 503 auto-healing, and rogue `.php` upload sanitization).
4. Update `bin/wp-isolate` CLI to manage the sentinel daemon and add `wp-isolate scan`.
5. Update tests, installer, and documentation.

**Tech Stack:** Bash, Linux POSIX ACL (`setfacl`/`getfacl`), OpenLiteSpeed (`lswsctrl`/`lshttpd`), systemd, Python 3.

**Spec:** [docs/superpowers/specs/2026-10-04-zero-touch-auto-isolation-design.md](file:///Users/ruanshan/Desktop/wp-isolate/docs/superpowers/specs/2026-10-04-zero-touch-auto-isolation-design.md)

## Global Constraints
- Target: aaPanel + OpenLiteSpeed on Ubuntu 22.04/24.04 and Debian 11/12.
- Backward compatibility: Existing `wp-isolate` CLI commands (`list`, `isolate`, `isolate-all`, `restore`, `status`, `clean`, `verify`, `repair`) must remain intact.
- Zero-Touch: Daily site additions on aaPanel must be automatically isolated after a 15-second debounce window without user intervention.
- Zero-Conflict: aaPanel site creation must never be interrupted or corrupted.

---

### Task 1: Granular POSIX ACLs in `lib/os_user.sh`

**Files:**
- Modify: `lib/os_user.sh:60-115`
- Test: `tests/test_os_user.sh`

- [ ] **Step 1: Update `tests/test_os_user.sh` with granular ACL tests**
- [ ] **Step 2: Run test to observe failure**
- [ ] **Step 3: Update `apply_site_permissions` in `lib/os_user.sh`**
  - Set `setfacl -R -m u:www:rx "$docroot"` and default `setfacl -R -d -m u:www:rx "$docroot"`.
  - Protect `wp-config.php` and `.env` with `chmod 640` and `setfacl -m u:www:0 "$conf_file"`.
  - If `$docroot/wp-content/uploads` exists, apply `setfacl -R -m u:www:rwx "$docroot/wp-content/uploads"` and default `rwx`.
- [ ] **Step 4: Run `bash tests/test_os_user.sh` and verify PASS**

---

### Task 2: Native OLS Uploads PHP Execution Blocker in `lib/ols_vhost.sh`

**Files:**
- Modify: `lib/ols_vhost.sh:124-145`
- Test: `tests/test_ols_vhost.sh`

- [ ] **Step 1: Update `tests/test_ols_vhost.sh` to check for uploads PHP blocking rewrite rules**
- [ ] **Step 2: Run test to observe failure**
- [ ] **Step 3: Update `isolate_ols_vhost` in `lib/ols_vhost.sh`**
  - Add rewrite rule blocking direct access to `wp-content/uploads/.*\.php$`.
- [ ] **Step 4: Run `bash tests/test_ols_vhost.sh` and verify PASS**

---

### Task 3: Build the Unified `wp-isolate-sentinel` Daemon

**Files:**
- Create: `bin/wp-isolate-sentinel`
- Modify: `install.sh`

- [ ] **Step 1: Create `bin/wp-isolate-sentinel` with:**
  - Inotify / directory poller on `/www/server/panel/vhost/openlitespeed/`.
  - 15-second settling debounce queue.
  - Handshake check (`is_aapanel_site_ready`: detail config complete with closing brace, docroot exists, `openlitespeed -t` passes).
  - Background 503 error monitor (incorporating `wp-isolate-healer`).
  - Rogue `.php` upload cleaner in `wp-content/uploads/`.
- [ ] **Step 2: Ensure executable permissions `chmod +x bin/wp-isolate-sentinel`**
- [ ] **Step 3: Verify syntax with `bash -n bin/wp-isolate-sentinel`**

---

### Task 4: Enhance CLI with Sentinel Management and Scanning in `bin/wp-isolate`

**Files:**
- Modify: `bin/wp-isolate`
- Test: `tests/test_cli_help.sh`

- [ ] **Step 1: Add `sentinel` command to `bin/wp-isolate` (`enable`, `disable`, `status`, `restart`)**
  - Create `/etc/systemd/system/wp-isolate-sentinel.service`.
  - Maintain backward compatibility with `healer` command (alias to sentinel).
- [ ] **Step 2: Add `scan` command to `bin/wp-isolate` (`wp-isolate scan <domain|all>`)**
  - Scans for rogue `.php` in `uploads/`, checks `.user.ini` for `auto_prepend_file`.
- [ ] **Step 3: Update `cmd_help` in `bin/wp-isolate`**
- [ ] **Step 4: Run `bash tests/test_cli_help.sh` and `bash tests/run_all_tests.sh`**

---

### Task 5: Update Installer, Documentation & Push to GitHub

**Files:**
- Modify: `install.sh`
- Modify: `README-vi.md`
- Modify: `README.md`

- [ ] **Step 1: Update `install.sh` to install and enable `wp-isolate-sentinel.service`**
- [ ] **Step 2: Update `README-vi.md` and `README.md` with v2.0 Zero-Touch instructions**
- [ ] **Step 3: Run complete test suite `bash tests/run_all_tests.sh`**
- [ ] **Step 4: Git commit all changes and push to GitHub repository**
- [ ] **Step 5: Provide step-by-step instructions for user to update VPS**
