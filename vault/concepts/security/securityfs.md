---
title: "securityfs"
category: concept
tags: [security, filesystem, lsm, ima, pseudo-filesystem]
subsystem: security
kernel_version: "2.6.14"
researched: 2026-04-17
status: complete
explained: "[[securityfs-explained]]"
sources:
  - https://lwn.net/Articles/153366/
  - https://lwn.net/Articles/153370/
  - https://lwn.net/Articles/722481/
  - https://lwn.net/Articles/829035/
  - https://elixir.bootlin.com/linux/latest/source/security/inode.c
  - https://docs.kernel.org/security/lsm-development.html
  - https://linux-ima.sourceforge.net/linux-ima-content.html-20110907
  - https://cateee.net/lkddb/web-lkddb/SECURITYFS.html
---

# securityfs

> 📘 Plain-language version: [[securityfs-explained]]

## Purpose

securityfs is a special-purpose virtual filesystem that provides a standardized interface for Linux Security Modules (LSMs) and other security subsystems to expose configuration, policy, status, and measurement data to userspace. Before its introduction in 2.6.14, each security module was creating its own custom filesystem (or abusing `/proc`), leading to proliferation of incompatible interfaces. securityfs gives every LSM a single, shared mount point at `/sys/kernel/security/` while still allowing each module full control over file semantics.

## Mental Model

Think of securityfs as a shared cork board mounted in a secure room. Any security module can pin documents to it (files, directories, symlinks), and each document can be as simple or complex as the module needs — a plain text status file or a sophisticated write-only policy loader. The room's lock (`rw,nosuid,noexec` mount flags) ensures nothing hanging there can be executed or escalate privileges. Modules own their corner of the board and are responsible for taking their documents down when they leave.

## How It Works

### Registration and Initialization

The filesystem is registered in `security/inode.c` via `register_filesystem()` during kernel init. Its `fs_context_operations` connect to the modern mount API: originally `get_tree_single()` created one system-wide superblock; since Linux 3.18 a `get_tree_keyed()` path uses the user namespace as the key, enabling per-namespace instances for container isolation. The superblock sets `rw,nosuid,noexec` mount flags and delegates inode cleanup through a custom `free_inode` hook in `struct super_operations`. Teardown uses `kill_litter_super()`.

systemd mounts securityfs early in boot at `/sys/kernel/security` if any LSM is present; it can also be mounted manually with:
```
mount -t securityfs security /sys/kernel/security
```
If not already mounted, LSMs will trigger the mount themselves during their own init.

### Creating Entries: The Three-Function API

The entire public interface fits in three functions declared in `<linux/security.h>`:

**`securityfs_create_file(name, mode, parent, data, fops)`** is the workhorse. It calls the internal `securityfs_create_dentry()`, which allocates a new inode via `new_inode()`, sets its type and permissions from `mode`, stores `data` in `inode->i_private` for later retrieval by file operations, and assigns `fops` to `inode->i_fop`. The dentry is instantiated with `d_instantiate()` and returned to the caller. The caller *must* save this dentry pointer — it is the only handle for later cleanup.

**`securityfs_create_dir(name, parent)`** is a thin wrapper around `securityfs_create_file()` with `S_IFDIR` mode and the default directory operations; it is how modules carve out their own subdirectory (e.g., AppArmor creates `/sys/kernel/security/apparmor/`, IMA creates `/sys/kernel/security/ima/`).

**`securityfs_create_symlink(name, parent, target, iops)`** creates a symbolic link. Until recently, the target string was heap-copied; a 2026 patch by Dmitry Antipov switched to `kstrdup_const()` so compile-time-constant targets reuse `.rodata` rather than burning heap.

### Removal and Cleanup

`securityfs_remove(dentry)` (and the recursive variant `securityfs_recursive_remove()`) must be called explicitly — there is no automatic garbage collection. The implementation calls `d_delete()` and drops the dentry reference acquired at creation time. Early kernels required directories to be empty before removal; the recursive variant removes this restriction. The 2026 LSM rework clarified reference counting: `dget()` is deferred to removal time rather than held from creation, simplifying per-namespace cleanup.

### Design Difference from sysfs and debugfs

sysfs enforces one-value-per-file and hides inode-level details behind kobject/attribute abstractions. debugfs imposes no rules at all and is considered a debugging aid with no stability guarantees. securityfs sits between: it exposes raw inode control (custom `file_operations`, full ioctl support, arbitrary read/write semantics) while still being a *specifically security-scoped* interface with a stable, documented API contract. The tradeoff is that each module must implement full file semantics rather than relying on sysfs abstractions — but this is exactly what IMA's policy loader, which needs to atomically activate a policy on file close, requires.

### LSM Framework Integration

The 2025–2026 LSM initialization rework by Paul Moore (34-patch series, `20251017202456.484010-36-paul@paul-moore.com`) tightened how LSMs register their securityfs interfaces. Patches 31 and 33 moved IMA/EVM initcalls into the LSM framework's initcall machinery, ensuring every module's filesystem interface is set up at a predictable point in the boot sequence. A regression in that series — securityfs/LSM init became too tightly coupled to unrelated security features, breaking `/proc/sys/vm/mmap_min_addr` when `CONFIG_SECURITY` was disabled — exposed the ongoing tension between integration and modularity.

At runtime, the root of securityfs contains an `lsm` file whose content is the comma-separated list of active LSMs, built dynamically under a spinlock by `lsm_read()`.

### IMA: The Largest Consumer

IMA (Integrity Measurement Architecture) builds the most complex securityfs subtree:

```
/sys/kernel/security/ima/
  policy                          ← write rules here; take effect on close
  ascii_runtime_measurements      ← human-readable: PCR | template hash | file hash | filename
  binary_runtime_measurements     ← binary log for remote attestation
  violations                      ← counter of appraisal failures
```

`ima/policy` is a write-only pseudo-file; each `write()` appends a rule, and `release()` atomically activates the complete ruleset. This "transactional close" pattern is only possible because securityfs lets IMA own the full `file_operations`. When TPM support is compiled in, IMA also creates per-algorithm measurement files named `ascii_runtime_measurements_<algo>` and `binary_runtime_measurements_<algo>`. A 2026 bug fix (`20260310-ima-oob-v6-1-dc111c846ff4@arista.com`) addressed a KASAN global-out-of-bounds crash when IMA encountered unsupported TPM hash algorithms (e.g., `TPM_ALG_SHA3_256`): rather than indexing `hash_algo_name[]` with an invalid index, unknown algorithms now get files named `_tpm_alg_<ID>`.

### Namespace Support (In Progress)

Today securityfs is effectively global: one mount serves all namespaces. `get_tree_keyed()` and the `FS_USERNS_MOUNT` flag lay the groundwork for per-user-namespace instances, and patches from Stefan Berger and James Bottomley have proposed extending IMA and AppArmor to use per-namespace securityfs trees. The design constraint is strict: "the namespace must be configured before any process appears in it, so that new policy rules apply to the very first process." None of this has merged into mainline as of 6.x; container isolation for LSM policy remains an open problem.

## Key Data Structures

**`struct file_system_type`** (`security/inode.c`) — registers securityfs with the VFS.
- `.name = "securityfs"`
- `.get_tree` — points to `get_tree_keyed()` (namespace-aware) or `get_tree_single()`
- `.kill_sb` — `kill_litter_super()` cleans up inodes on unmount

**`struct super_operations`** (`security/inode.c`) — superblock vtable.
- `.statfs` — reports filesystem stats
- `.free_inode` — custom inode destructor; called from RCU callback to free per-inode state

**`struct inode`** (VFS, `include/linux/fs.h`) — each securityfs file/dir/symlink gets one.
- `i_private` — stores the `data` pointer passed to `securityfs_create_file()`; retrieved by file operations to reach module-private state
- `i_fop` — points to caller-supplied `file_operations`

## Key Functions / Entry Points

**`securityfs_create_file()`** (`security/inode.c`) — primary entry point for all LSMs; calls internal `securityfs_create_dentry()` to allocate inode and dentry.

**`securityfs_create_dir()`** (`security/inode.c`) — wrapper that sets `S_IFDIR`; typically the first call a module makes to claim its namespace subdirectory.

**`securityfs_create_symlink()`** (`security/inode.c`) — creates a symlink; uses `kstrdup_const()` for the target string since Linux 6.x+.

**`securityfs_remove()`** (`security/inode.c`) — explicit teardown; calls `d_delete()` and drops dentry reference.

**`securityfs_recursive_remove()`** (`security/inode.c`) — removes an entire subtree; used during LSM unload to avoid having to tear down each entry individually.

**`init_securityfs()`** (`security/inode.c`) — called from `security_init()` during kernel boot; calls `register_filesystem(&fs_type)`.

## Important Flags & Config Options

**`CONFIG_SECURITYFS`** — enables the securityfs filesystem. Boolean, available since 2.6.28. Required for IMA, EVM, AppArmor, Smack, TOMOYO, and most other LSMs. Default off; most distributions enable it.

**Mount flags (`rw,nosuid,noexec`)** — always applied at mount time. `nosuid` prevents setuid/setgid escalation; `noexec` prevents execution of files stored there. These are not configurable per-mount.

**`FS_USERNS_MOUNT`** — filesystem type flag that allows mounting in non-initial user namespaces. Set on the `file_system_type`; enables the namespace-keyed superblock path.

**`CONFIG_IMA`** / **`CONFIG_EVM`** — the primary consumers of securityfs; enabling either requires `CONFIG_SECURITYFS`.

## Interactions with Other Subsystems

- **↑ Userspace**: LSM tools (aa-status, ima-evm-utils, tpm2-tools) read policy and measurement data directly from `/sys/kernel/security/`. Policy is written there (e.g., `echo "measure ..." > /sys/kernel/security/ima/policy`).
- **→ [[VFS]]**: securityfs is built atop the VFS inode/dentry layer. It calls `new_inode()`, `d_instantiate()`, `d_delete()`, and `kill_litter_super()` — standard VFS primitives.
- **→ [[LSM framework]]**: `security_init()` calls `init_securityfs()`; LSMs register their filesystem interfaces through the LSM initcall chain.
- **→ [[IMA]]**: IMA's `ima_fs_init()` creates the `ima/` subtree, including policy loader, measurement lists, and per-TPM-algorithm log files.
- **→ [[kernel-keyring]]**: EVM stores HMAC keys in the kernel keyring, then exposes EVM status through securityfs.
- **← [[AppArmor]]**: AppArmor's `apparmor/` subtree is one of the largest securityfs consumers; profile loading, enforcement mode control, and notification interfaces all live there.
- **← [[Smack]]**: SmackFS (`/sys/kernel/security/smack/`) uses securityfs for label and rule management (see [[smackfs]]).
- **← [[TPM]]**: TPM event log and PCR interfaces are exposed via securityfs by the IMA/TPM integration layer.

## Design Decisions & Tradeoffs

**Minimal API, maximum module freedom.** The choice to provide only three creation functions — and to expose raw `file_operations` — was deliberate. An early LWN discussion (2005) considered something sysfs-like with more structure, but the consensus was that security modules need ioctl support and complex atomic semantics (e.g., IMA's policy-on-close) that sysfs abstractions would obstruct.

**No automatic cleanup.** Requiring explicit `securityfs_remove()` calls was chosen over a reference-counted auto-cleanup scheme. The rationale: automatic cleanup could race with concurrent readers, and security data should only disappear when the module explicitly revokes it. The cost is that buggy modules can leave stale entries, but this is viewed as a developer discipline problem rather than a framework problem.

**Global mount vs. namespace isolation.** The decision to use a single system-wide mount (pre-3.18) simplified the implementation enormously but made securityfs incompatible with container workloads that need per-namespace security policies. The `get_tree_keyed()` path added later is the architectural answer, but LSMs have not yet been updated to fully exploit it — the per-namespace IMA and AppArmor work is still in-progress as of 2026.

**Why not procfs or sysfs?** procfs is process-centric and has no natural home for non-process security data; its file creation API is also more cumbersome. sysfs enforces kobject-based hierarchy and one-value-per-file semantics that are at odds with policy files containing multiple structured rules. securityfs provides a neutral ground with no imposed model.

## How It Has Evolved

- **2.6.14 (2005)**: Initial introduction. Replaced per-module custom filesystems (e.g., `seclvl` dropped ~88 lines of sysfs infrastructure). Mount point `/sys/kernel/security/`.
- **2.6.30 (2009)**: IMA integrated, making securityfs the interface for measurement lists and TPM attestation.
- **3.18 (2014)**: `get_tree_keyed()` path added; `FS_USERNS_MOUNT` flag enables per-namespace superblocks. Groundwork for container isolation laid but not yet exploited by LSMs.
- **5.x**: `securityfs_recursive_remove()` added to simplify teardown of module subtrees without manually listing each dentry.
- **6.10 (2024)**: TPM interposer-attack detection added; TPM-related securityfs interfaces extended.
- **2025–2026**: LSM initialization rework (Paul Moore, 34-patch series) consolidates all LSM securityfs registration through the unified LSM initcall framework; IMA hash-algo OOB bug fixed; symlink target optimization with `kstrdup_const()`.

## Further Reading

1. **[LWN: Security filesystem](https://lwn.net/Articles/153366/)** (2005) — original introduction, explains motivation and early design choices.
2. **[LWN: seclvl securityfs patch](https://lwn.net/Articles/153370/)** (2005) — concrete example of the code simplification securityfs enabled.
3. **[LWN: IMA namespace support](https://lwn.net/Articles/829035/)** (2021) — ongoing work to give containers per-namespace IMA policy and measurement lists via securityfs.
4. **[kernel.org: LSM development guide](https://docs.kernel.org/security/lsm-development.html)** — official guide to writing an LSM, includes securityfs API usage.
5. **[Bootlin Elixir: security/inode.c](https://elixir.bootlin.com/linux/latest/source/security/inode.c)** — annotated source, the canonical reference.
6. **[linux-ima.sourceforge.net](https://linux-ima.sourceforge.net/linux-ima-content.html-20110907)** — IMA design overview showing securityfs integration.

## LKML Highlights

- **`20260317141135.133339-1-dmantipov@yandex.ru`** — Dmitry Antipov switches securityfs symlink targets to `kstrdup_const()`, reducing heap pressure; merged by Paul Moore with "can easily back out if non-const targets appear."
- **`20260310-ima-oob-v6-1-dc111c846ff4@arista.com`** — Dmitry Safonov fixes a KASAN global-out-of-bounds in IMA's securityfs file creation when `crypto_id == HASH_ALGO__LAST` (unsupported TPM algorithm), creating `_tpm_alg_<ID>` named files instead of crashing.
- **`20251017202456.484010-36-paul@paul-moore.com`** — Paul Moore's 34-patch LSM initialization rework; patches 31 and 33 consolidate IMA/EVM securityfs registration through the unified LSM initcall chain; a regression in this series exposed over-coupling between securityfs init and unrelated security tunables.
