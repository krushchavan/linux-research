---
title: "Kernel Keyring (Key Retention Service)"
category: concept
tags: [security, keys, cryptography, authentication, keyring]
subsystem: security
kernel_version: "2.6.10"
researched: 2026-04-17
status: complete
explained: "[[kernel-keyring-explained]]"
sources:
  - https://kernel-internals.org/crypto/keyring/
  - https://docs.kernel.org/security/keys/core.html
  - https://docs.kernel.org/security/keys/request-key.html
  - https://docs.kernel.org/security/keys/trusted-encrypted.html
  - https://lwn.net/Articles/210502/
  - https://lwn.net/Articles/48008/
  - https://blog.cloudflare.com/the-linux-kernel-key-retention-service-and-why-you-should-use-it-in-your-next-application/
---

# Kernel Keyring (Key Retention Service)

> 📘 Plain-language version: [[kernel-keyring-explained]]

## Purpose

The Kernel Key Retention Service (KKRS) provides a kernel-managed store for cryptographic keys, authentication tokens, and similar sensitive material. Without it, each subsystem that needs to cache credentials would either reinvent its own locking, lifetime management, and quota enforcement, or push sensitive material through userspace where process memory bugs can expose it. KKRS centralises all of that: keys live as first-class kernel objects with reference counting, permissions, expiry, garbage collection, and optional hardware backing — and subsystems such as [[fscrypt]], [[dm-crypt]], and [[IMA]] share one consistent interface.

## Mental Model

Think of keyrings as directories and keys as files. Just as a filesystem path search walks a directory tree to find a file, `request_key()` walks a process's subscribed keyring tree to find a matching key. The tree is per-process but the leaves can be shared (a session keyring is inherited across `fork`/`exec`; a user keyring is shared across all processes with the same UID). "Opening a key" returns a reference — the key stays alive as long as any reference is held, just like a file descriptor keeps an inode alive. The analogy breaks down in one place: keys can be *instantiated by userspace* via an upcall, so finding an absent key can trigger `/sbin/request-key` to populate it, much like a kernel module auto-load.

## How It Works

### Key Lifecycle and the `struct key`

Every object in the keyring subsystem — whether a raw credential or a keyring container — is represented by `struct key` (`include/linux/key.h`). When `add_key(2)` is called, `key_alloc()` allocates one and assigns it a unique 32-bit serial number drawn from a global IDR. The key starts in the *uninstantiated* state: allocated but not yet populated. `key_instantiate_and_link()` (or the type-specific `.instantiate()` callback) moves it to *instantiated* once the payload is set.

```c
struct key {
    refcount_t          usage;       /* reference count — key freed at zero */
    key_serial_t        serial;      /* global unique ID, used by keyctl(2) */
    struct key_type    *type;        /* ops vector: instantiate, match, read … */
    union key_payload   payload;     /* type-specific data, RCU-protected */
    struct key_user    *user;        /* owner — tracks per-UID quota */
    kuid_t              uid;         /* owning UID */
    kgid_t              gid;         /* owning GID */
    key_perm_t          perm;        /* 32-bit permission bitmap */
    time64_t            expiry;      /* absolute expiry, 0 = immortal */
    unsigned long       flags;       /* KEY_FLAG_INSTANTIATED, KEY_FLAG_REVOKED … */
};
```

Payload access is protected by one of three mechanisms depending on what the key type needs: direct access for immutable payloads; a `key->sem` read/write semaphore for types that allow in-place updates; or full RCU via `rcu_dereference()`/`rcu_assign_pointer()` for types that require lock-free read access from interrupt context.

Keys have a finite set of states. From *instantiated* a key can be *revoked* (by `KEYCTL_REVOKE` or by the type itself), become *expired* when `time64_t expiry` passes, or transition to *dead* when its type module is unregistered. Dead, revoked, and expired keys are unlinked from their keyrings and freed by a background garbage collector (`key_gc_work`) after a configurable delay (`/proc/sys/kernel/keys/gc_delay`, default 5 minutes).

### The Keyring Hierarchy

A keyring is itself a key of type `"keyring"`, whose payload is an `assoc_array` (kernel's generic radix tree) of `key_ref_t` pointers. Every process inherits a tree of keyrings searched in order:

| Shorthand | Name | Lifetime | Shared? |
|-----------|------|----------|---------|
| `@t` | thread keyring | discarded on `clone()`/`fork()` | per-thread |
| `@p` | process keyring | discarded on `clone()` unless `CLONE_THREAD` | per-thread-group |
| `@s` | session keyring | inherited across `fork()`/`exec()` | inherited subtree |
| `@u` | user keyring | UID lifetime (login session) | all processes same UID |
| `@us` | user-session keyring | UID lifetime | default for new sessions |

Above these per-process keyrings sit system keyrings, created at boot and globally accessible regardless of process context:
- `.builtin_trusted_keys` — X.509 certificates compiled or loaded as trusted for IMA/module signing
- `.secondary_trusted_keys` — additional certs added at runtime
- `.ima` — IMA measurement signing keys
- `.blacklist` — revoked certificates

### Searching: `request_key()` and the Upcall

`request_key(2)` is the heart of the service. It searches the calling process's keyring tree — thread → process → session → user — using `search_process_keyrings()`. Within each keyring, `keyring_search_rcu()` iterates the `assoc_array`, calling the type's `.match_preparse()` callback to test each key against the description. The first key found that is instantiated, not expired, and for which the caller holds *search* permission is returned.

If no key is found, the kernel creates an *uninstantiated* key `U` and an *authorisation key* `V`. `V` encodes the original requester's credentials and points to `U`. The kernel then forks and execs `/sbin/request-key`, passing `V`'s serial number in the new process's session keyring. The `request-key` helper uses `KEYCTL_ASSUME_AUTHORITY` to adopt `V`'s authority — meaning it can search the *original* requester's keyrings to gather the material needed — and then calls `KEYCTL_INSTANTIATE` to populate `U`. Once instantiated, `V` is automatically revoked so the authority cannot be reused. If instantiation fails, a *negative* key (type `".negative"`) is installed temporarily so repeated lookups don't re-trigger the upcall storm.

This upcall design keeps policy out of the kernel: the kernel defines what a key is and how to find one; userspace defines how to obtain one that doesn't exist yet. NFS uses this to fetch Kerberos tickets; the DNS resolver uses it to cache lookups; ecryptfs uses it to unwrap passphrases.

### Permission Model

`key_perm_t` is a 32-bit mask divided into four 8-bit fields for *possessor* (a process that has the key linked into one of its keyrings), *user* (UID match), *group* (GID match), and *other*. Each 8-bit field carries six permission bits:

| Bit | Permission | Allows |
|-----|-----------|--------|
| 0x01 | `view` | Read key description and metadata via `KEYCTL_DESCRIBE` |
| 0x02 | `read` | Read key payload via `KEYCTL_READ` |
| 0x04 | `write` | Update or instantiate key via `KEYCTL_UPDATE` |
| 0x08 | `search` | Find key during `request_key()` traversal |
| 0x10 | `link` | Link key into a keyring |
| 0x20 | `setattr` | Change owner, GID, permissions, timeout |

Permission checks (`key_task_permission()`) happen before any payload is accessed. The [[LSM framework]] (`security_key_permission()`) sits directly below the POSIX-style check, giving SELinux, Smack, and others a hook to enforce mandatory policy on top.

### Quota Enforcement

Each user has a per-`struct key_user` quota tracked in two counters: `qnkeys` (number of keys owned) and `qnbytes` (sum of payload + description sizes). At allocation time, `key_alloc()` calls `key_user_lookup()` to find or create the `key_user` for the owner's UID in the namespace, then checks and atomically increments the counters. Process and thread keyrings are exempt from quota to avoid deadlocking the key machinery against itself. Root has separate, larger limits. All four limits are tunable via `/proc/sys/kernel/keys/{maxkeys,maxbytes,root_maxkeys,root_maxbytes}`.

## Key Data Structures

**`struct key_type`** (`include/linux/key-type.h`) — the operations vector that defines a key flavour; registered with `register_key_type()`.
- `name` — string name, e.g. `"user"`, `"keyring"`, `"asymmetric"`
- `preparse()` / `free_preparse()` — parse description/payload before key creation (runs outside locks)
- `instantiate()` — populate payload from preparse result (runs under key write-lock)
- `update()` — update payload for an existing key
- `match_preparse()` / `match_free()` — prepare a criteria object for keyring search
- `revoke()` / `destroy()` — clean up on revoke or free
- `read()` — copy payload to userspace for `KEYCTL_READ`
- `describe()` — append textual description for `/proc/keys`

**`struct key_user`** (`security/keys/key.c`) — per-UID accounting.
- `usage` — refcount
- `qnkeys`, `qnbytes` — current quota usage (atomic)
- `nkeys`, `nikeys` — total and instantiated key count

**`key_ref_t`** — a tagged pointer to `struct key`; the low bit is set when the pointer was obtained via a "possessor" path (i.e. the key is linked into one of the caller's keyrings), which gates possessor permission checks.

## Key Functions / Entry Points

**`add_key()`** (`security/keys/keyctl.c`) — syscall entry; calls `key_create_or_update()` → `key_alloc()` + `key_instantiate_and_link()`.

**`request_key()`** (`security/keys/request_key.c`) — searches keyrings; triggers upcall if absent; called by filesystems and kernel services via `request_key()` or `request_key_tag()`.

**`keyctl()`** (`security/keys/keyctl.c`) — multiplexed syscall for all key management operations; dispatches on the `cmd` argument to ≥30 sub-operations.

**`register_key_type()`** / `unregister_key_type()` (`security/keys/key.c`) — register a new key flavour; typically called from a module `init` function.

**`key_get()`** / `key_put()`** — increment/decrement reference count; `key_put()` queues GC work at zero.

**`keyring_search()`** (`security/keys/keyring.c`) — recursive RCU-safe search of an `assoc_array`; called by `search_process_keyrings()`.

**`key_validate()`** — checks that a key is instantiated, not revoked, not expired; fast-path gate before permission checks.

## Key Types in Depth

**`"user"`** — arbitrary byte blobs created from userspace; payload is a `user_key_payload` holding a raw buffer. Readable and writable from userspace given appropriate permissions. Used by `mount.cifs`, `pam_keyring`, and applications that need a simple kernel-managed secret store.

**`"logon"`** — identical layout to `"user"` but `.read()` is unimplemented; userspace can push a secret in but cannot pull it out. The key description must follow the `"subsystem:name"` convention. Used by fscrypt (`fscrypt:`) and dm-crypt to store key material that the kernel derives session keys from, without the plaintext ever returning to userspace after initial injection.

**`"keyring"`** — payload is an `assoc_array`; operations manipulate the set of links. Creating a keyring with `add_key("keyring", …)` gives a user-manageable container; the standard per-process keyrings (`@t`, `@p`, `@s`) are created by the kernel on demand.

**`"asymmetric"`** — container for public-key material (RSA, EC, X.509 certificates). The subtype (`x509_key_subtype` or `pkcs7_key_subtype`) provides the actual operations. IMA signs file hashes with keys from `.ima`; module loading verifies signatures against `.builtin_trusted_keys` using this type. Userspace can perform `KEYCTL_PKEY_SIGN`, `KEYCTL_PKEY_VERIFY`, `KEYCTL_PKEY_ENCRYPT`, and `KEYCTL_PKEY_DECRYPT` operations.

**`"trusted"`** — symmetric keys generated inside a Trust Source (TPM, TEE, NXP CAAM, i.MX DCP, IBM PowerVM PKWM). The kernel never sees plaintext; it works only with a hardware-sealed *blob* stored in userspace and unsealed on demand. Keys can be bound to PCR values so that unsealing fails if the measured boot chain has changed. Created with `keyctl add trusted "new 32"`.

**`"encrypted"`** — software analogue of trusted keys: the payload is AES-CBC encrypted under a master key that is itself a trusted or user key. Gives strong confidentiality guarantees without requiring TPM hardware. Format is `"new [ecryptfs|default] <master-key-desc> <keylen>"`.

## Important Flags & Config Options

| Symbol | Effect |
|--------|--------|
| `CONFIG_KEYS` | Enables the entire subsystem; most other key Kconfig symbols depend on it |
| `CONFIG_TRUSTED_KEYS` | Trusted key type; pulls in TPM or TEE support |
| `CONFIG_ENCRYPTED_KEYS` | Encrypted key type |
| `CONFIG_ASYMMETRIC_KEY_TYPE` | Asymmetric key type + X.509 parser |
| `CONFIG_KEY_DH_OPERATIONS` | `KEYCTL_DH_COMPUTE` and `KEYCTL_KDF_DERIVE` |
| `/proc/sys/kernel/keys/gc_delay` | Seconds before revoked/expired keys are GC'd (default 300) |
| `/proc/sys/kernel/keys/maxkeys` | Max keys per non-root UID (default 200) |
| `/proc/sys/kernel/keys/maxbytes` | Max key payload bytes per non-root UID (default 20000) |
| `/proc/keys` | Readable list of all keys visible to current process |
| `/proc/key-users` | Per-UID quota statistics |

## Interactions with Other Subsystems

- **↑ Userspace**: `add_key(2)`, `request_key(2)`, `keyctl(2)` provide the full management surface; `libkeyutils` wraps these for applications. `/sbin/request-key` is the privileged upcall helper.
- **→ [[fscrypt]]**: fscrypt stores master keys as `"logon"` or `"user"` keys; the kernel's `fscrypt_get_encryption_key()` calls `request_key()` with type `"fscrypt"` to find session keys without re-deriving from the master.
- **→ [[dm-crypt]]**: dm-crypt uses `"logon"` keys to hold volume encryption keys; the `cryptsetup` tool injects keys and the kernel retains them for the volume lifetime.
- **→ [[kernel-crypto-api]]**: Trusted and encrypted key operations call the kernel crypto API (`crypto_aead_encrypt`, etc.) internally for AES-GCM sealing and unsealing.
- **→ IMA**: IMA loads signing certificates into `.ima` as `"asymmetric"` keys at boot; the integrity measurement architecture verifies file hashes against them.
- **← [[LSM framework]]**: Every permission check calls `security_key_permission()`; SELinux uses the `"key"` security class; Smack labels keys at creation time.
- **← NFS/CIFS/AFS**: These filesystems call `request_key()` to obtain Kerberos tickets and SPNEGO tokens cached as `"user"` keys in the session keyring; the upcall triggers `rpc.gssd` or `cifs.upcall` to fetch new tickets from the KDC.

## Design Decisions & Tradeoffs

**Userspace policy via `/sbin/request-key`**: The decision to delegate instantiation to a userspace helper keeps kernel complexity low and allows each service to define its own key-fetching strategy. The cost is an extra fork/exec on cache miss, which is acceptable because key misses are rare hot-path events (filesystem mounts, first network connection). The auth-key mechanism that temporarily grants the helper the requester's identity is a neat solution to the privilege question that avoids exposing the requester's credentials directly.

**Possessor permission as a fourth subject**: Standard Unix permission models have user/group/other. The keyring adds "possessor" — a process that has the key linked into one of its keyrings. This was necessary because the natural ownership model breaks for shared credentials: a Kerberos TGT should be usable by all processes in a session regardless of which UID created it. Possessor permission handles this without changing UIDs.

**Key namespaces tied to user namespaces (5.2)**: The decision to anchor key namespaces to user namespaces was pragmatic — user namespaces already carry a security boundary and are the natural container isolation primitive. The tradeoff is that container isolation of keyrings requires `CLONE_NEWUSER`, which carries broader capability implications that not all deployments want.

**Quota per UID, not per namespace**: The quota system predates namespaces and counts against UID 0 in a user namespace as root but doesn't isolate quotas per container. This is a known limitation that can allow one container to exhaust another's quota if they share a UID in the root namespace.

## How It Has Evolved

**2.6.10 (2004)** — Initial submission by David Howells. Core data structures, `user`/`keyring` types, `request_key()` with upcall. Motivated primarily by NFS Kerberos credential caching needs.

**2.6.12–2.6.15** — `logon` type added; quota enforcement; `/proc/keys` and `/proc/key-users`.

**~2.6.36** — `trusted` and `encrypted` key types merged; TPM-backed key sealing for disk encryption use cases.

**3.x** — `asymmetric` key type merged alongside IMA v2, enabling signed kernel modules and file integrity verification using kernel-managed certificates.

**4.x** — `KEYCTL_DH_COMPUTE` and `KEYCTL_KDF_DERIVE` for Diffie-Hellman operations; `KEYCTL_PKEY_*` for sign/verify/encrypt/decrypt.

**5.2 (2019)** — Key namespaces tied to user namespaces (`struct key_namespace`, `CONFIG_KEY_NOTIFICATIONS`), enabling per-container key isolation at the user namespace boundary.

**5.13+** — TEE (OP-TEE), CAAM, DCP, and PowerVM trust sources for `trusted` keys; ECDSA asymmetric subtype.

## Further Reading

1. [Kernel Key Management — LWN.net (2007)](https://lwn.net/Articles/210502/) — concise design rationale and original motivation
2. [Linux kernel keyring: Key Retention Service docs (kernel.org)](https://docs.kernel.org/security/keys/core.html) — complete API reference
3. [Request-key service docs (kernel.org)](https://docs.kernel.org/security/keys/request-key.html) — upcall mechanism details
4. [Trusted and Encrypted Keys (kernel.org)](https://docs.kernel.org/security/keys/trusted-encrypted.html) — TPM/TEE integration
5. [Cloudflare: The Linux Kernel Key Retention Service](https://blog.cloudflare.com/the-linux-kernel-key-retention-service-and-why-you-should-use-it-in-your-next-application/) — practical use case: kernel-resident SSH keys to prevent memory-safety exploits
6. [Authentication/encryption key retention — LWN (2004)](https://lwn.net/Articles/48008/) — original proposal

## LKML Highlights

> **Initial implementation (2004)** — `implement in-kernel keys & keyring management [try #2]`, David Howells, [LWN.net thread](https://lwn.net/Articles/97066/). The debate centred on whether to put this in the kernel at all vs. a userspace daemon; Howells argued that kernel-managed keys are necessary for filesystems that need to access credentials from interrupt context, where userspace daemons cannot help.

> **Key namespaces RFC (2019)** — Howells proposed tying key namespaces to user namespaces so container runtimes get per-container `@u`/`@s` keyrings; reviewers debated whether full namespace isolation was worth the added complexity given that most container workloads never exercise the keyring API directly.

> **ECDSA support for asymmetric keys** — [LWN.net coverage](https://lwn.net/Articles/911180/). The thread explored extending `KEYCTL_PKEY_*` operations to EC curves; the main tradeoff was kernel-crypto dependency vs. offloading to hardware accelerators.
