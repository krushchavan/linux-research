---
title: "Smack Access Engine — Explained"
category: explained
original: "[[smack-access-engine]]"
subsystem: security
tags: [explained, security, smack, mac, access-control]
converted: 2026-09-25
---

# The Smack access engine, explained

> Plain-language companion to [[smack-access-engine|the technical note]]. Same facts, fewer identifiers.

## The problem

Smack has about 100 hooks: file opens, signals, socket connects and more. If each hook worked out "is this allowed?" in its own way, the same rule could mean slightly different things in different places, and the policy would stop being predictable. Every decision needs to go through **one** function with one set of rules.

## The idea in one paragraph

Every Smack hook boils its question down to the same form: **may a subject with label S have access M to an object with label O?** One engine answers it, like a firewall rule lookup with a few built-in cases. It first checks five **hard-wired special cases** that no administrator can change. If none apply, it looks in the subject's own list of rules for an explicit grant. If nothing grants the access, it's denied.

## Step by step

### Step 1: Resolve both labels
The hook looks up the subject's label (from the process's credentials) and the object's label (from the inode, socket, etc.) as canonical entries in the [[smack-label-registry-explained|label registry]], so labels can be compared as pointers rather than strings.

### Step 2: Check the five built-in cases, in order
1. **Subject is "\*" (star):** deny everything. Star is Smack's quarantine label; a process with it can reach nothing, and no rule or capability overrides this.
2. **Subject is "^" (hat):** allow reading and executing, deny writing and appending. For observers such as monitoring daemons that need read-only access to everything without hand-written rules.
3. **Object is "\_" (floor):** allow reading and executing for anyone. Floor marks public resources, like world-readable files but enforced as mandatory policy.
4. **Object is "\*" (star):** allow everything for anyone. Used for shared endpoints, such as pipes, that every domain must use.
5. **Same label:** a process can always fully access objects carrying its own label, with no self-rules needed.

### Step 3: Look up an explicit rule
This is the key step. If no built-in case applied, the engine takes a read lock on the subject's rules and searches them. Each subject label has its own **sorted tree of rules**, keyed by object label, so the search takes logarithmic time in *that subject's* rule count. A rule lists the modes granted: read, write, execute, append, transmute, lock, and (in development builds) bringup. Access is granted only if the rule includes **every** requested mode; otherwise it's denied, and with no matching rule, it's denied by default.

### Step 4: The privileged override
Most hooks use a wrapper that works for the current process. Before returning a denial, it checks whether the process holds the **MAC override** capability; if so, the denial is overturned and noted for audit. A separate **MAC admin** capability governs *changing* policy (loading rules, relabelling). An "only this label" setting can restrict both capabilities to processes carrying one specific label, so holding the capability alone isn't enough.

### Step 5: Log the decision
If logging is on, the engine writes an audit record with both labels, the requested access, the result and the calling hook. A runtime setting chooses between silence, denials only (typical in production), grants only, or everything.

## The picture

```text
 hook: may S do M to O?
   S == "*" ─────────────────────▶ deny
   S == "^" ─────────────────────▶ read/exec yes, write no
   O == "_" ─────────────────────▶ read/exec yes
   O == "*" ─────────────────────▶ yes
   S == O   ─────────────────────▶ yes
   S's rule tree: find O ──▶ rule ⊇ M ? yes : deny
                   none  ──▶ deny
   denied & has MAC-override capability? ──▶ overturned (audited)
```

## Tradeoffs

- **What it gives you:** one consistent meaning for every rule across all hooks; predictable built-in labels that behave the same on every Smack system; cheap per-subject lookups.
- **What it costs / requires:** rules aren't **transitive**: if A may reach B and B may reach C, A still can't reach C without its own rule. That's simpler to reason about than SELinux's type transitions, but big policies need many explicit rules.
- **Where it bites:** the five special labels are fixed and can't be repurposed. That was deliberate, for predictability, but it means those label names are reserved everywhere.

## How it got here

- **2.6.25:** all rules in one list, searched linearly.
- **3.x:** a sorted rule tree per subject, which mattered as Tizen deployments grew past 1000 rules.
- **4.x:** transmute and lock modes, plus a "bringup" mode that grants access while logging it, for developing policy incrementally.
- **5.x:** per-process temporary rules, used when a process relabels itself.

## Related

- Technical version: [[smack-access-engine]]
- [[smack|Smack]], [[smack-label-registry-explained|Label registry]], [[smack-inode-and-task-labeling-explained|Inode and task labelling]], [[smack-network-labeling-explained|Network labelling]], [[smackfs|smackfs]]
- [[security-explained|Security subsystem]], [[lsm-framework-explained|LSM framework]], [[capabilities-explained|Capabilities]], [[linux-audit-explained|Audit]], [[selinux-explained|SELinux]]
