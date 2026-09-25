---
title: "Linux Capabilities — Explained"
category: explained
original: "[[capabilities]]"
subsystem: security
tags: [explained, security, capabilities, privileges]
converted: 2026-09-25
---

# Linux capabilities, explained

> Plain-language companion to [[capabilities|the technical note]]. Same facts, fewer identifiers.

## The problem

Traditional Unix privilege is a single switch: root can do everything, everyone else can't. A service that needs one privileged operation, such as binding to port 80, has to run as full root, which also lets it load kernel modules, reset the clock and bypass every file permission. Any bug in that service becomes a bug with root's full power.

## The idea in one paragraph

Split root into about **40 separate powers**, called capabilities: one to bind low ports, one to set the clock, one to load drivers, and so on. A process holds only the ones it needs. Each process has **five sets** of capabilities that control what it can use now, what it could use later, and what survives when it runs another program. The kernel checks for the specific capability at each privileged operation. The model arrived in Linux 2.2 (1999), based on the withdrawn POSIX.1e draft.

## Step by step

### Step 1: The five sets
Every process's credentials hold five capability sets:
- **bounding:** a hard ceiling. Dropping a capability from it is permanent, for this process and all its descendants, even through setuid. Privilege-separating daemons use this to guarantee they can never get a power back.
- **permitted:** the pool the process may draw from; it can never rise above the bounding set.
- **effective:** what's **actually checked**. A process can lower a capability here temporarily, keep it in permitted, and raise it again later.
- **inheritable:** capabilities that survive running a new program, but only if the program file also lists them. Process and file must agree, so privileges don't leak into arbitrary programs.
- **ambient** (4.3): capabilities passed to children and across program execution **without** the file agreeing. This fixed the problem of launching an ordinary helper, such as a Python script, that needs a capability from its parent. Only capabilities already both effective and inheritable can be ambient.

### Step 2: The check
At a privileged operation such as binding a port below 1024, the kernel asks: does the current process have this capability in its effective set? It reads the credentials safely under RCU. This is the key step for containers: for resources owned by a namespace, the question is whether the process has the capability **in the user namespace that owns that resource**, not in the whole system. A process that's root inside a user namespace therefore has powers only inside it.

### Step 3: Capabilities on files
An executable can carry capabilities in an extended attribute, set with a small tool. When it runs, the kernel combines the file's capabilities with the caller's:
- the new permitted set comes from what both the process and file allow to be inherited, plus what the file grants outright (limited by the bounding set)
- if the file says "effective", everything permitted becomes effective at once

That's how `ping` can hold just the raw-socket capability instead of being setuid root.

### Step 4: "No new privileges"
A process can set a one-way flag that stops it, and everything it later runs, from gaining privileges through program execution: setuid bits and file capabilities are ignored. It can never be cleared. Unprivileged processes must set it before installing a seccomp filter.

### Step 5: The catch-all capability
The **system-administration** capability covers more than 40 unrelated operations: mounting, namespaces, unrestricted ptrace, keyrings, quotas, resource limits, hostname changes and more. It grew over 25 years as the "everything else" bucket, and holding it is effectively root. Modern practice is to avoid it, use narrower capabilities, and give new privileged operations their own.

## The picture

```text
 bounding  ██████████░░░░   ← ceiling; dropped bits never come back
 permitted ███████░░░░░░░   ← pool (≤ bounding)
 effective ███░░░░░░░░░░░   ← what the kernel checks right now
 inheritable / ambient      ← what crosses into the next program

 bind(port 80) ─▶ "net bind service" in effective set,
                  in the user namespace owning this network namespace?  ✓ / EPERM
```

## Tradeoffs

- **What it gives you:** least privilege; services hold only the powers they need, and daemons can permanently shed the rest. Capabilities scoped to user namespaces make privileged operations possible inside containers without real root.
- **What it costs / requires:** five interacting sets and the rules for combining them at program execution are notoriously hard to reason about; ambient capabilities were added in 4.3 to patch a practical gap. Capability checks are implemented as a security module of their own, always loaded first.
- **Where it bites:** the system-administration capability. Granting it hands over nearly everything, so a capability profile that includes it offers little real confinement.

## How it got here

- **2.2 (1999):** capabilities introduced, following the withdrawn POSIX.1e draft.
- **4.3 (2015):** ambient capabilities, so non-setuid helper programs can inherit their parent's powers.
- About 40 capabilities are defined today, with new ones added rarely.

## Related

- Technical version: [[capabilities]]
- [[security-explained|Security subsystem]], [[credentials-explained|Credentials]], [[lsm-framework|LSM framework]], [[seccomp-bpf|seccomp]], [[user-namespaces|User namespaces]], [[apparmor-explained|AppArmor]]
