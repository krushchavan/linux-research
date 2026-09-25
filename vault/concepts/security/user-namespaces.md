---
title: "User Namespaces"
category: concept
tags: [security, namespaces, capabilities, containers, uid-mapping]
subsystem: security
kernel_version: "3.8"
researched: 2026-04-17
status: complete
explained: "[[user-namespaces-explained]]"
sources:
  - https://kernel-internals.org/security/user-namespaces/
  - https://man7.org/linux/man-pages/man7/user_namespaces.7.html
  - https://lwn.net/Articles/532593/
  - https://lwn.net/Articles/491310/
  - https://lwn.net/Articles/903580/
  - https://lwn.net/Articles/978846/
  - https://lwn.net/Articles/812504/
  - https://lwn.net/Articles/837566/
  - https://www.kernel.org/doc/html/latest/userspace-api/no_new_privs.html
  - https://edera.dev/stories/user-namespaces-are-not-a-security-boundary
---

# User Namespaces

> 📘 Plain-language version: [[user-namespaces-explained]]

## Purpose

User namespaces isolate the security identifiers — user IDs, group IDs, and capabilities — that the kernel uses to make privilege decisions. A process inside a user namespace can hold UID 0 and a full capability set *within the namespace* while remaining entirely unprivileged from the host's perspective. Without this isolation there would be no safe path to rootless containers: any container runtime that needed to perform privileged operations (bind-mounting, creating network devices, modifying /proc) would have to run as real root on the host.

## Mental Model

Think of a user namespace as a **privilege bubble**. Inside the bubble a process can be king — it has every capability, it owns every file it creates, it can manage other namespaces pinned to its bubble. But the bubble itself is owned by an ordinary host user, and the kernel tracks that ownership rigorously. Anything the "root" inside the bubble tries to do that would affect the world *outside* the bubble gets checked against the host user's actual credentials, not the bubble credentials — and ordinary users cannot affect global state.

## How It Works

### Creation and the uid_map bootstrap

The journey starts with a `clone(CLONE_NEWUSER)` call (or `unshare(CLONE_NEWUSER)` for the calling thread itself). The kernel allocates a new `struct user_namespace` — defined in `include/linux/user_namespace.h` — and links it into the namespace hierarchy: every namespace except the initial one has a `parent` pointer back to its creator's namespace.

The newly created child is in a liminal state. It has no UID/GID mapping yet, so *every* ID lookup for files and credentials returns the overflow value (`/proc/sys/kernel/overflowuid`, default 65534). The child process is blocked from doing much until the *parent* writes mapping information to `/proc/<child-pid>/uid_map` and `/proc/<child-pid>/gid_map`.

The mapping file format is three whitespace-separated integers per line:

```
<id-inside-ns>  <id-in-parent-ns>  <count>
```

For example, writing `0 1000 1` says: "namespace UID 0 is the same entity as parent-namespace UID 1000, and that mapping covers a range of 1 ID." Up to 340 such lines are allowed (raised from the original limit of 5 in Linux 4.16). The kernel stores these in the `uid_gid_map` embedded in `struct user_namespace`, represented as an array of `uid_gid_extent` structures, each with fields `first` (start inside), `lower_first` (start in parent), and `count`.

The mapping can only be written *once*; subsequent attempts fail with `EPERM`. This immutability is deliberate — once a namespace's identity is pinned, no one can retroactively claim a different host UID.

There is a security wrinkle for unprivileged callers: without `CAP_SETUID`/`CAP_SETGID` in the *parent* namespace, you may only write a single-line mapping, and that single line must map the writer's own effective UID (or GID). This prevents an unprivileged user from granting namespace UIDs that they do not actually own on the host.

### The kuid_t / kgid_t type barrier

Eric Biederman's core engineering insight (proposed around 2012) was to stop storing UIDs as plain `uid_t` integers and instead introduce the opaque `kuid_t` and `kgid_t` types. These are tiny single-field structs, which means the C compiler catches at build time any attempt to pass a raw integer where a kernel UID is expected, or to compare UIDs from different namespaces. The vast majority of kernel code does not need to know anything about namespaces; it just passes `kuid_t` values around, and the few spots that must translate between namespaces call explicit helpers:

- **`make_kuid(ns, uid)`** — translates a userspace `uid_t` (as seen from namespace `ns`) into a kernel-internal `kuid_t`. Returns `INVALID_UID` if there is no mapping for that `uid` in `ns`.
- **`from_kuid(ns, kuid)`** — the reverse: given a `kuid_t`, produce the `uid_t` that a process in `ns` would see. Returns `(uid_t)-1` if no mapping exists.
- **`from_kuid_munged(ns, kuid)`** — like `from_kuid` but falls back to `overflowuid` instead of `-1`, safe to use in places such as `stat(2)` responses where a failure return would confuse userspace.

All credential fields in `struct cred` — `uid`, `gid`, `suid`, `sgid`, `euid`, `egid`, `fsuid`, `fsgid` — are `kuid_t`/`kgid_t`, so the type discipline propagates automatically.

### Capabilities inside the namespace

When the first process enters a new user namespace, it receives a full capability set *scoped to that namespace*. The kernel's capability code tracks which user namespace "owns" a namespace: the owner is identified by the effective UID of the creator at the time `clone` was called. Capability checks use two different helpers:

- **`capable(cap)`** — checks the capability against the *initial* (global) user namespace. Only genuine host root passes this.
- **`ns_capable(ns, cap)`** — checks the capability against `ns`. A namespace "root" passes this for its own namespace and any child namespace it owns, but not the parent.

This hierarchy means that a container with `CAP_NET_ADMIN` inside its user namespace can configure the network interfaces visible inside that namespace, but cannot touch the host's networking stack (which lives in the initial namespace).

There is one notable capability pitfall: when a process with non-zero UIDs calls `execve()`, the kernel clears the capability sets (standard POSIX behaviour). If a container's first process creates a new user namespace and then `exec`s a shell *before* the parent has written `uid_map`, it will lose all capabilities. Container runtimes avoid this by synchronising on a pipe: parent writes the map, signals "done", child only then calls `execve()`.

### The setgroups gate

A subtle security issue: inside a user namespace, a process might call `setgroups(2)` to *drop* supplementary groups. If a file is accessible to a group that the user is currently in but should not be in (think of a setgid executable owned by a privileged group), dropping groups could bypass a restriction. To prevent this, the kernel requires that before writing to `gid_map`, an unprivileged writer must first write `deny` to `/proc/<pid>/setgroups`. Writing `deny` permanently disables `setgroups(2)` in that namespace and all its descendants. A privileged writer (with `CAP_SETGID` in the parent) can write `allow` first, then write the GID map without this restriction.

### ID-mapped mounts

User namespace UID mapping is namespace-global: all filesystems seen by that namespace use the same UID translation. For containers sharing a common filesystem image, this causes friction — container A maps host 100000–165535 to namespace 0–65535, but container B uses host 200000–265535, yet they both need to access the same image with the same ownership layout.

Linux 5.12 introduced **idmapped mounts** (`mount_setattr(2)` with `MOUNT_ATTR_IDMAP`). The key change is a new `mnt_user_ns` pointer in `struct vfsmount` that holds a per-mount ID mapping. When the VFS performs ownership checks on that mount, it applies the mount-level mapping *before* the namespace-level mapping. This allows each container to have its own independent view of file ownership on a shared volume without needing a separate shiftfs-style stacking filesystem. The mapping is immutable once applied.

### Nested namespaces

User namespaces can nest up to 32 levels deep (enforced since Linux 3.11; `EUSERS` returned if exceeded). Capabilities inherited at one level extend downward: if you own a user namespace, you can create child namespaces and are considered to have capabilities in them. The `parent` pointer in `struct user_namespace` forms a tree rooted at `init_user_ns`, which is statically allocated and has a UID map covering the entire 32-bit ID space.

## Key Data Structures

**`struct user_namespace`** (`include/linux/user_namespace.h`) — the central object representing one privilege bubble.
- `uid_map`, `gid_map`, `projid_map` — embedded `uid_gid_map` arrays of up to 340 `uid_gid_extent` entries each
- `parent` — pointer to the parent namespace; `NULL` for `init_user_ns`
- `owner` — `kuid_t` of the user who created this namespace (the "owner" for capability inheritance)
- `flags` — e.g. `USERNS_SETGROUPS_ALLOWED`
- `ucounts` — per-user accounting to enforce `user.max_user_namespaces`

**`struct uid_gid_extent`** (`include/linux/user_namespace.h`) — one contiguous range in a UID/GID map.
- `first` — start of the range as seen from inside the namespace
- `lower_first` — start of the corresponding range in the parent namespace
- `count` — number of IDs in the range

**`struct cred`** (`include/linux/cred.h`) — per-process credential block; carries `user_ns` pointer, all `kuid_t`/`kgid_t` fields, and the four capability sets (`cap_permitted`, `cap_effective`, `cap_inheritable`, `cap_bounding`).

## Key Functions / Entry Points

**`create_user_ns()`** (`kernel/user_namespace.c`) — called from `copy_creds()` during `clone(CLONE_NEWUSER)`; allocates and initialises the new namespace, links it to the parent.

**`proc_uid_map_write()`** (`kernel/user_namespace.c`) — the write handler for `/proc/<pid>/uid_map`; validates permissions, parses the three-column format, calls `map_write()` to populate `uid_gid_extent` arrays.

**`map_id_range_down()`** / **`map_id_up()`** (`kernel/user_namespace.c`) — low-level range-search helpers used by `make_kuid()` and `from_kuid()`.

**`ns_capable(ns, cap)`** (`kernel/capability.c`) — checks whether the current task holds `cap` with respect to `ns`; the standard test for namespace-scoped privilege.

**`security_create_user_ns()`** — LSM hook (added Linux 6.1) called before namespace creation; allows security modules to audit or reject the attempt with a meaningful error.

## Important Flags & Config Options

| Symbol / knob | What it does |
|---|---|
| `CONFIG_USER_NS` | Compile-time enable; required for any namespace functionality |
| `kernel.unprivileged_userns_clone` | Debian/Ubuntu sysctl; set to `0` to block unprivileged creation |
| `user.max_user_namespaces` | System-wide cap on total user namespaces; default varies by distro |
| `/proc/sys/kernel/overflowuid` | Value returned for unmapped UIDs (default 65534) |
| `/proc/sys/kernel/overflowgid` | Same for GIDs |
| `MOUNT_ATTR_IDMAP` | Flag for `mount_setattr(2)` to attach an ID-mapped mount |

**Distro defaults:** Ubuntu 23.10+ restricts unprivileged namespace creation via AppArmor by default, with a whitelist for known-safe applications. Debian ships with `kernel.unprivileged_userns_clone=0` and requires explicitly opting in.

## Interactions with Other Subsystems

- **↑ Userspace**: container runtimes (`podman`, `runc`, Docker) call `clone(CLONE_NEWUSER)`, write uid/gid maps, then optionally use `newuidmap`/`newgidmap` setuid helpers (from `shadow-utils`) to establish multi-range mappings; applications call `prctl(PR_SET_NO_NEW_PRIVS)` in conjunction with seccomp for unprivileged filter installation.
- **→ [[VFS]]**: every `inode` lookup that resolves permissions calls `make_kuid()` / `from_kuid()` to translate IDs; idmapped mounts inject an additional translation at `struct vfsmount` level.
- **→ [[Capabilities]]**: `ns_capable()` gates all namespace-scoped privilege checks; `capable()` gates global checks; the two helpers are the main interface between user namespaces and the capability subsystem.
- **→ [[LSM Framework]]**: the `security_create_user_ns()` hook lets SELinux, AppArmor, and Smack policy intercept namespace creation; `ns_capable()` consults LSM `capable` hooks.
- **→ [[Network Namespaces]]**: network namespaces are "owned" by a user namespace; the owning user namespace determines what capabilities are needed to administer the network namespace.
- **← [[cgroups]]**: `user.max_user_namespaces` is enforced through `struct ucounts`, which ties per-user resource accounting to the user namespace hierarchy.
- **← [[seccomp-bpf]]**: `prctl(PR_SET_SECCOMP)` with mode 2 (BPF) is restricted to processes with `no_new_privs` set *or* `CAP_SYS_ADMIN` in the calling namespace; user namespaces enable unprivileged seccomp usage.

## Design Decisions & Tradeoffs

**kuid_t as type firewall:** Biederman's decision to use an opaque struct instead of `typedef unsigned int kuid_t` means mixing namespaced and raw IDs is a compile-time error everywhere in the kernel, not a subtle runtime bug. The cost is some verbosity; the payoff is that the entire kernel was audited for namespace-awareness at merge time rather than left to be discovered in production.

**Immutable mappings:** Once written, uid/gid maps cannot be changed. This prevents a process from claiming a different identity mid-flight and makes capability analysis tractable. The tradeoff is that tooling (e.g., container checkpoint/restore) must account for this — you cannot remap a running namespace.

**Unprivileged namespace creation is optional:** The security community reached no consensus on whether `CLONE_NEWUSER` should be available to any user by default. Distributions that care more about attack-surface reduction (Debian, hardened Ubuntu) disable it; distributions that prioritise developer ergonomics (Arch, stock Fedora) leave it on. The kernel ships both paths and lets distributors decide.

**No per-namespace capability restriction (yet):** The proposal by Jonathan Calmels (2023) for a `userns capability set` — a way to restrict which capabilities are granted when a user namespace is created — received mixed feedback. Capability maintainer Serge Hallyn was enthusiastic; LSM maintainer Paul Moore rejected the LSM hook portion. As of 6.x the feature is not merged; namespace root always gets all capabilities scoped to that namespace.

**Attack surface is real:** User namespaces expose a much larger slice of the kernel syscall surface to unprivileged code. CVE-2022-0185 (heap overflow via `fsconfig`), CVE-2023-32233 (nf_tables UAF), and CVE-2024-1086 (nf_tables double-free) all require user namespaces to reach from unprivileged userspace. This is a structural consequence of the design, not a fixable bug.

## How It Has Evolved

**Linux 2.6.x (early):** Initial user namespace scaffolding existed but was extremely limited — only one namespace existed in practice and there was no UID mapping.

**Linux 3.8 (2013):** First kernel version where most subsystems supported user namespaces enough to be usable. Eric Biederman's 43-patch series introducing `kuid_t`/`kgid_t` and wiring up VFS, networking, and IPC was merged.

**Linux 3.11:** Maximum nesting depth of 32 enforced.

**Linux 3.19:** `setgroups` file added to `/proc/<pid>` to close the group-drop privilege bypass.

**Linux 4.9:** `newuidmap`/`newgidmap` helpers and `/etc/subuid` support stabilised for rootless container workflows.

**Linux 4.16:** uid/gid map line limit raised from 5 to 340, enabling containers with large subordinate ID ranges to use fewer mappings.

**Linux 5.12:** Idmapped mounts (`mount_setattr(2)` + `MOUNT_ATTR_IDMAP`) merged, replacing the shiftfs approach and providing per-mount independent ID translation.

**Linux 6.1:** `security_create_user_ns()` LSM hook merged, giving security modules a proper interception point for namespace creation.

**Ubuntu 23.10 / Debian ongoing:** Distributions move toward default-deny policies for unprivileged namespace creation using AppArmor profiles and sysctl knobs, in response to the accumulation of CVEs that required user namespaces.

## Further Reading

1. [Namespaces in operation, part 5: User namespaces — LWN.net](https://lwn.net/Articles/532593/) — the classic deep-dive reference by Michael Kerrisk
2. [A new approach to user namespaces — LWN.net](https://lwn.net/Articles/491310/) — the kuid_t design and Biederman's 43-patch series
3. [A security-module hook for user-namespace creation — LWN.net](https://lwn.net/Articles/903580/)
4. [A capability set for user namespaces — LWN.net](https://lwn.net/Articles/978846/) — the Calmels proposal and community debate
5. [ID mapping for mounted filesystems — LWN.net](https://lwn.net/Articles/837566/) — idmapped mounts design
6. [Filesystem UID mapping: shiftfs (yet another approach) — LWN.net](https://lwn.net/Articles/812504/)
7. [user_namespaces(7) man page](https://man7.org/linux/man-pages/man7/user_namespaces.7.html) — authoritative API reference
8. [Linux User Namespaces: 262% More Kernel Attack Surface — Edera](https://edera.dev/stories/user-namespaces-are-not-a-security-boundary) — attack-surface analysis

## LKML Highlights

**[PATCH 0/43] Completing the user namespace (2012)** — Eric Biederman's landmark series introducing `kuid_t`/`kgid_t` and wiring user namespace support across VFS, networking, IPC, and proc. The cover letter articulates the "type barrier" design philosophy: make UID mixing a compile-time error rather than a runtime footgun.

**security_create_user_ns LSM hook (2022–2023)** — Frederick Lawler's patch set adding a proper access-control hook for namespace creation. Paul Moore's review focused on ensuring the hook supports auditing, not just rejection, reflecting the LSM subsystem's dual mandate of access-control *and* observability.

**userns capability set (Calmels, 2023)** — Jonathan Calmels proposed restricting which capabilities namespace root receives at creation. The debate exposed a fundamental tension: Serge Hallyn wanted more granular capability control for containers; Paul Moore was concerned about LSM hooks that let BPF modules manipulate capability sets outside the established security module framework.
