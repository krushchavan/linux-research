---
title: "Kernel Keyring (Key Retention Service) — Explained"
category: explained
original: "[[kernel-keyring]]"
subsystem: security
tags: [explained, security, keyring, keys, request-key]
converted: 2026-09-25
---

# The kernel keyring, explained

> Plain-language companion to [[kernel-keyring|the technical note]]. Same facts, fewer identifiers.

## The problem

Many parts of the kernel need to hold secrets: disk-encryption keys, file-encryption keys, Kerberos tickets for network filesystems, certificates for checking signed modules. Without a shared service, each would reinvent locking, lifetimes, expiry and per-user limits, or keep secrets in user-space memory, where a memory bug could expose them. Some of these secrets are needed in contexts where a user-space daemon can't help, such as a filesystem working inside the kernel.

## The idea in one paragraph

Treat **keyrings like directories and keys like files**. Each process sees a small tree of keyrings; looking up a key walks that tree, much as a path lookup walks directories. Keys are reference-counted kernel objects with owners, permissions, expiry and garbage collection. The twist: if a key isn't found, the kernel can **ask user space to fetch it**, running a helper program with temporary authority to create the missing key, a bit like loading a kernel module on demand. The kernel defines what a key is and how to find one; user space decides how to obtain one that doesn't exist yet.

## Step by step

### Step 1: A key is an object
Each key has a type, a description, a payload, an owner (user and group), a permission mask, an optional expiry time, a reference count, and a unique serial number. Creating one allocates it in an **uninstantiated** state; filling in its payload makes it **instantiated**. Depending on the type, the payload is fixed once set, updated under a lock, or read lock-free with RCU.

### Step 2: Keys wear out
An instantiated key can be **revoked**, can **expire**, or can become **dead** if its type's module is unloaded. A background garbage collector unlinks and frees such keys after a delay (5 minutes by default).

### Step 3: The keyring tree
A keyring is itself a key whose payload is a set of links to other keys. Every process searches its keyrings in order:
- **thread keyring:** private to one thread
- **process keyring:** shared by a thread group
- **session keyring:** inherited across fork and exec
- **user keyring:** shared by every process with the same user ID

System-wide keyrings created at boot sit alongside: trusted certificates built in or added at runtime, IMA's signing keys, and a blacklist of revoked certificates.

### Step 4: Search
A lookup walks thread, then process, then session, then user keyrings, checking each key with its type's matching rule. The first key that is instantiated, not expired, and searchable by the caller wins.

### Step 5: Missing? Ask user space
This is the key step. If nothing is found, the kernel creates an empty placeholder key plus an **authorisation key** that records who asked and points at the placeholder. It then starts a helper program with that authorisation key in its session. The helper **assumes the authority**, which lets it search the *original requester's* keyrings for anything it needs, obtains the secret (say, a Kerberos ticket), and fills in the placeholder. The authorisation is revoked straight away so it can't be reused. If fetching fails, a short-lived **negative** key is installed so repeated lookups don't set off a storm of helper runs. NFS uses this for Kerberos tickets, the DNS resolver for caching lookups, and ecryptfs for unwrapping passphrases.

### Step 6: Permissions with a "possessor"
Permissions are checked before any payload is touched, for four kinds of subject: **possessor** (a process that has the key linked into one of its keyrings), matching user, matching group, and everyone else. Each can be allowed to view, read, write, search, link or change attributes. "Possessor" exists because ownership alone doesn't fit shared credentials: a session's Kerberos ticket should be usable by every process in that session, whichever user created it. Security modules then get a hook to apply mandatory policy on top.

### Step 7: Quotas
Each user has limits on how many keys they own and how many bytes those keys use (by default 200 keys and 20,000 bytes for ordinary users, with larger limits for root). Process and thread keyrings are exempt, so the key machinery can't deadlock against its own limits.

### Step 8: Key types
- **user:** arbitrary byte blobs that user space can write and read back
- **logon:** like user, but **can't be read back** once written; fscrypt and dm-crypt keep keys here so the plaintext never returns to user space
- **keyring:** a container of links
- **asymmetric:** public keys and certificates, used to check signed modules and IMA signatures, and for sign, verify, encrypt and decrypt operations
- **trusted:** keys generated and sealed inside hardware (a TPM or other trusted environment); the kernel only handles the sealed blob, and keys can be tied to measured-boot values so unsealing fails if the boot chain changed
- **encrypted:** a software equivalent, wrapped under a trusted or user master key

## The picture

```text
 request "nfs:ticket" ─▶ thread ─▶ process ─▶ session ─▶ user keyrings
                                              found? ──yes──▶ reference returned
                                                │ no
                                                ▼
   placeholder key U  +  authorisation key V (who asked, points to U)
                ─▶ helper program assumes V's authority
                   searches requester's keyrings, fetches ticket, fills U
                ─▶ V revoked;  on failure: short-lived negative key
```

## Tradeoffs

- **What it gives you:** one consistent, kernel-resident store for secrets with lifetimes, permissions, quotas and optional hardware backing, shared by fscrypt, dm-crypt, IMA and network filesystems; secrets that can be pushed in but never read back out.
- **What it costs / requires:** a cache miss means forking and running a helper, acceptable because misses are rare (mounts, first connections). Trusted and encrypted keys use the kernel crypto API internally.
- **Where it bites:** key namespaces (5.2) are tied to user namespaces, so isolating keyrings per container means creating a user namespace, with its broader capability implications. Quotas are counted per user ID, not per container, so two containers sharing a user ID in the root namespace can exhaust each other's quota.

## How it got here

- **2.6.10 (2004):** David Howells's initial implementation, driven mainly by NFS Kerberos credential caching. The debate was whether this belonged in the kernel at all; Howells argued filesystems need credentials in contexts where a user-space daemon can't help.
- **2.6.12–2.6.15:** the logon type, quotas and the /proc views.
- **~2.6.36:** trusted and encrypted keys for disk encryption.
- **3.x:** asymmetric keys, enabling signed modules and file integrity checks.
- **4.x:** Diffie-Hellman and public-key operations from user space.
- **5.2 (2019):** key namespaces tied to user namespaces, after debate over whether full isolation was worth the complexity. **5.13+:** more hardware trust sources for trusted keys, and ECDSA keys.

## Related

- Technical version: [[kernel-keyring]]
- [[security-explained|Security subsystem]], [[credentials-explained|Credentials]], [[ima-explained|IMA]], [[tpm-explained|TPM]], [[lsm-framework-explained|LSM framework]], [[user-namespaces-explained|User namespaces]]
- [[fscrypt-explained|fscrypt]], [[dm-crypt-explained|dm-crypt]], [[kernel-crypto-api-explained|Kernel crypto API]], [[nfs-explained|NFS]], [[rpcsec-gss-and-kerberos-explained|RPCSEC_GSS and Kerberos]]
