---
title: "Per-CPU Variables"
category: concept
tags: [per-cpu, locking, smp, cache-coherency, preemption, memory]
subsystem: locking
kernel_version: "2.6.x (static DEFINE_PER_CPU); unified chunk allocator v2.6.30+"
researched: 2026-04-13
status: complete
sources:
  - https://lwn.net/Articles/22911/
  - https://lwn.net/Articles/258238/
  - https://lwn.net/Articles/452884/
  - https://docs.kernel.org/core-api/this_cpu_ops.html
  - https://0xax.gitbook.io/linux-insides/summary/concepts/linux-cpu-1
  - https://kernel-internals.org/locking/
---

# Per-CPU Variables

## Purpose

On an SMP system, every time two CPUs read and modify a shared variable, the cache-coherency protocol forces the cache line holding that variable to bounce between cores — a round-trip that can cost hundreds of nanoseconds. Per-CPU variables sidestep this entirely: instead of one shared instance, the kernel maintains a private copy for each CPU, so each core only ever touches its own copy and cache-line ownership never transfers. The secondary benefit is that most accesses become lock-free by construction, because a CPU cannot race with itself on its own copy.

## Mental Model

Think of a per-CPU variable as a row of post-boxes — one per processor — all at the same "address" within each CPU's private address space. When you write to the box, you write to your CPU's box only. When you read it, you read your own box. Nobody else's mail ever touches your box unless they explicitly reach across, which the design deliberately discourages. The kernel makes this concrete with a segment register (on x86: `gs:`) that points each CPU to its own contiguous region of memory; the "address" of a per-CPU variable is really an offset into that region.

## How It Works

### Memory layout and static allocation

When the kernel image is compiled, every `DEFINE_PER_CPU(type, name)` call places `name` into a special linker section called `.data..percpu`. This section is not used directly at runtime — it is a template. During `setup_per_cpu_areas()` at boot, the kernel allocates `nr_cpu_ids` copies of this section, one per possible CPU, and populates the `__per_cpu_offset[NR_CPUS]` array with the byte distance between each CPU's copy and the original template. From that point on, accessing CPU `N`'s copy of variable `v` is arithmetic: take the address of `v` in the template and add `__per_cpu_offset[N]`.

The first chunk is structured in three sub-regions: a **static area** (the `.data..percpu` image itself), a **reserved area** (space set aside for statically-allocated per-CPU data from loadable modules), and a **dynamic area** (a slab-like pool for `alloc_percpu()` calls at runtime). The `percpu_alloc=` kernel parameter selects between the **embed** first-chunk allocator (default — places the entire first chunk in early bootmem so physical addresses are contiguous per NUMA node) and the **page** allocator (maps pages individually, useful when contiguous memory is scarce).

### Dynamic allocation

When a driver or subsystem needs per-CPU data whose size is not known at compile time, it calls `alloc_percpu(type)` (or `__alloc_percpu(size, align)` for raw byte counts). The allocator carves the requested block from the dynamic area of every CPU's chunk and returns an opaque `__percpu`-annotated pointer — conceptually a `void __percpu *` that is *not* a real address and cannot be dereferenced directly. `free_percpu()` returns the block. Each CPU's physical copy is located by adding the per-CPU base offset for that CPU to the returned pseudo-pointer.

### Safe access: the preemption invariant

The fundamental constraint is: **a thread must not migrate to a different CPU between the moment it determines "I am CPU N" and the moment it finishes operating on CPU N's data.** If the scheduler moves the thread mid-operation, it would continue modifying the old CPU's copy while now running on a different CPU — exactly the race per-CPU variables are supposed to eliminate.

The classical solution is `get_cpu_var(var)` / `put_cpu_var(var)`. `get_cpu_var` calls `preempt_disable()`, then returns a reference to the current CPU's copy. The caller does its work, then calls `put_cpu_var`, which calls `preempt_enable()`. The disable/enable bracket guarantees the CPU identity is stable throughout. Sleeping is forbidden inside this bracket.

`per_cpu(var, cpu)` and `per_cpu_ptr(ptr, cpu)` skip the preemption guard and are appropriate when the CPU number is already known and stable (e.g., in a CPU hotplug callback, or when the caller holds a lock that implies CPU affinity).

### this_cpu operations: architectural shortcut

The modern and preferred approach is the `this_cpu_*` family of operations — `this_cpu_read()`, `this_cpu_write()`, `this_cpu_inc()`, `this_cpu_add()`, `this_cpu_xchg()`, `this_cpu_cmpxchg()`, and so on. On x86, the segment register (`gs:` in kernel mode on x86-64) already holds the base address of the current CPU's per-CPU area. A `this_cpu_inc(x)` therefore compiles to a single `inc gs:[x]` instruction: the CPU adds the segment base *and* performs the operation atomically at the instruction level, with no separate address calculation step. Because there is no window between "compute the address" and "use the address," preemption cannot insert a CPU migration in the middle — the operation is inherently atomic with respect to CPU identity, though **not** with respect to concurrent interrupt handlers on the same CPU.

The lighter `__this_cpu_*` variants omit even the implicit memory-barrier semantics. They are correct only when the caller has already disabled preemption and interrupts through other means (e.g., inside an interrupt handler, or within a `local_irq_save()` block).

`this_cpu_ptr(pvar)` returns the current CPU's pointer into a dynamically allocated per-CPU block. It is the dynamic equivalent of `get_cpu_var` but without the preemption disable — safe to use when the caller is already in a non-preemptible context.

### Remote access

Reading another CPU's per-CPU variable with `per_cpu(var, cpu)` is generally safe as a snapshot, since cache coherency ensures the read is atomic at word granularity. Remote *writes* are strongly discouraged: they can race with `this_cpu` read-modify-write operations on the remote CPU, which have no lock semantics. The recommended pattern for triggering a remote update is to use an IPI to wake the target CPU and have it update its own variable.

## Key Data Structures

**`__per_cpu_offset[NR_CPUS]`** (`include/asm-generic/percpu.h`) — per-CPU base offsets; `__per_cpu_offset[cpu]` is added to a per-CPU "address" to get the real kernel virtual address for that CPU's copy.

**`struct pcpu_alloc_info`** (`include/linux/percpu.h`) — describes how to lay out the first chunk across NUMA groups; carries `unit_size`, `atom_size`, `alloc_size`, and an array of `struct pcpu_group_info` entries.

**`struct pcpu_chunk`** (`mm/percpu.c`) — represents one allocation chunk in the dynamic per-CPU allocator; tracks free/used blocks via a bitmap and links into the per-CPU allocator's slot lists.

**`DEFINE_PER_CPU(type, name)`** (`include/linux/percpu-defs.h`) — places `name` in `.data..percpu` and annotates its type with `__percpu` so sparse can warn when a raw pointer is used instead of a per-CPU accessor.

## Key Functions / Entry Points

**`setup_per_cpu_areas()`** (`arch/x86/kernel/setup_percpu.c` and generic `init/main.c`) — called once at boot; selects the first-chunk allocator, calls `pcpu_embed_first_chunk()` or `pcpu_page_first_chunk()`, and fills `__per_cpu_offset[]`.

**`pcpu_embed_first_chunk()`** / **`pcpu_page_first_chunk()`** (`mm/percpu.c`) — the two first-chunk allocators; `embed` allocates from memblock and maps the whole first chunk contiguously per NUMA node, while `page` maps individual pages for each CPU unit.

**`alloc_percpu(type)`** / **`__alloc_percpu(size, align)`** (`mm/percpu.c`) — dynamically allocate a per-CPU variable; returns a `void __percpu *` pseudo-pointer.

**`free_percpu(ptr)`** (`mm/percpu.c`) — release a dynamically allocated per-CPU variable.

**`get_cpu_var(var)`** / **`put_cpu_var(var)`** (`include/linux/percpu-defs.h`) — classic bracketed accessor; disables/enables preemption around direct access to a static per-CPU variable.

**`per_cpu_ptr(ptr, cpu)`** (`include/linux/percpu-defs.h`) — compute the real pointer for CPU `cpu` from a dynamic per-CPU pseudo-pointer; no preemption manipulation.

**`this_cpu_ptr(pvar)`** (`include/linux/percpu-defs.h`) — like `per_cpu_ptr` but for the current CPU; efficient on architectures with a segment-register shortcut.

## Important Flags & Config Options

**`CONFIG_SMP`** — per-CPU variables collapse to plain global variables on UP builds; the `DEFINE_PER_CPU` infrastructure still compiles but `__per_cpu_offset[]` has a single entry and `this_cpu_*` is a no-op wrapper.

**`CONFIG_PREEMPT` / `CONFIG_PREEMPT_RT`** — under `PREEMPT_RT`, spinlocks are sleepable, so holding a per-CPU reference while a sleepable lock is taken requires extra caution; the PREEMPT_RT work explored making migration-prevention the responsibility of lock acquisition rather than explicit preemption disabling.

**`percpu_alloc=embed|page`** — kernel command-line parameter that selects the first-chunk allocator; `embed` is the default and generally preferred for NUMA systems; `page` is a fallback for early-boot environments with fragmented physical memory.

**`PERCPU_MODULE_RESERVE`** — compile-time constant (default 8 KiB) specifying how much of the first chunk's reserved area is earmarked for module static per-CPU variables.

## Interactions with Other Subsystems

- **↑ Userspace**: no direct exposure; userspace sees aggregated statistics (e.g. `/proc/stat` CPU counters) which are sums of per-CPU counters maintained with per-CPU variables.
- **→ Memory management**: `alloc_percpu()` calls into `pcpu_alloc()`, which ultimately calls `vmalloc_alloc` / `memblock` for backing pages; the first chunk lives in bootmem, later chunks in vmalloc space.
- **→ CPU hotplug**: when a CPU is brought online, its per-CPU area is already allocated (sized for all *possible* CPUs at boot); the allocator initialises its chunk state. When a CPU goes offline, any per-CPU counters it holds are migrated or zeroed by the respective subsystems.
- **← Scheduler**: `this_cpu` operations require preemption to be disabled or for the operation to be architecturally atomic; the scheduler cooperates by not migrating a task between preempt_disable() / preempt_enable() brackets.
- **← [[RCU Read-Copy-Update]]**: RCU's grace-period tracking uses per-CPU state (`rcu_data`) heavily; `this_cpu_ptr(&rcu_data)` is one of the hottest per-CPU accesses in the kernel.
- **← [[Interrupt Handling]]**: softirq and hardirq handlers run in non-preemptible contexts, so `this_cpu_*` operations inside interrupt handlers are safe without additional guards; `__this_cpu_*` is appropriate there since interrupts are already disabled.

## Design Decisions & Tradeoffs

**Why not just use atomic operations on shared variables?** Atomic operations still bounce the cache line — every `atomic_inc` on a shared counter causes the cache line to travel from one core's L1/L2 to another's. Per-CPU counters eliminate that traffic entirely: each CPU increments its own copy, and the true total is summed lazily (e.g. for `/proc/stat`).

**Why the two-level design (static + dynamic)?** Static per-CPU variables (`.data..percpu`) are cheaper at access time — their addresses are link-time constants — but they bloat the kernel image proportionally to the number of CPUs. The dynamic allocator allows subsystems that are not always present (drivers, modules) to contribute per-CPU data without paying the static cost for every kernel build.

**The NR_CPUS problem and Christoph Lameter's 2008 rework**: before v2.6.30, the dynamic per-CPU allocator allocated an array of NR_CPUS pointers, wasting cache lines when the actual CPU count was far below the compile-time maximum. Lameter's unified chunk allocator replaced this with a contiguous-chunk design where all CPUs' data is laid out with a fixed stride in virtual address space, eliminating the pointer array and reducing per-allocation overhead.

**PREEMPT_RT and the migration-lock idea**: Thomas Gleixner proposed that rather than requiring explicit `preempt_disable()`, the scheduler could track per-CPU variable ownership through lock acquisition and prevent migration implicitly. This would eliminate latency spikes caused by low-priority threads holding preemption disabled on RT systems. The approach was validated by an extension to Lockdep to detect inconsistently locked per-CPU accesses.

**`this_cpu_*` vs `get_cpu_var`**: the `this_cpu` family is strictly superior on architectures that support it (x86, arm64 with `TPIDR_EL1`) because the address calculation and operation collapse into one instruction. The explicit `get_cpu_var`/`put_cpu_var` pattern remains useful on architectures without a segment-register shortcut and in code paths where a long block of work must be done on one CPU's data.

## How It Has Evolved

- **2.6.0–2.6.12**: `DEFINE_PER_CPU` and `get_cpu_var`/`per_cpu()` introduced; per-CPU data for statistics and per-CPU page lists made the allocator a hot path.
- **2.6.30 (2009)**: Christoph Lameter rewrote the dynamic per-CPU allocator into the unified chunk-based design (`mm/percpu.c`), replacing the old array-of-pointers approach and shrinking metadata overhead significantly.
- **~3.x**: `this_cpu_*` operations formalised as the preferred API; architecture backends added optimised single-instruction implementations for x86 and arm64.
- **5.x+**: PREEMPT_RT integration work explored removing `preempt_disable()` requirements for per-CPU access by tying CPU affinity to lock ownership; Lockdep gained annotations to detect unsafe per-CPU accesses.

## Further Reading

1. [Better per-CPU variables — LWN (2008)](https://lwn.net/Articles/258238/) — Christoph Lameter's unified-chunk allocator proposal
2. [Per-CPU variables and the realtime tree — LWN (2012)](https://lwn.net/Articles/452884/) — Gleixner/Zijlstra's migration-lock idea for PREEMPT_RT
3. [Driver porting: per-CPU variables — LWN (2003)](https://lwn.net/Articles/22911/) — original introduction for driver authors
4. [this_cpu operations — kernel.org docs](https://docs.kernel.org/core-api/this_cpu_ops.html) — authoritative reference for the `this_cpu_*` API
5. [Per-CPU variables — linux-insides](https://0xax.gitbook.io/linux-insides/summary/concepts/linux-cpu-1) — walk-through of initialisation and access with source references

## LKML Highlights

- **Christoph Lameter's unified per-CPU allocator (2008)**: A multi-message thread debating whether static `.data..percpu` bloat was acceptable vs. the complexity of the new chunk allocator; the chunk design won on memory savings for large NR_CPUS builds.
- **PREEMPT_RT migration-lock proposal**: Gleixner and Zijlstra argued that requiring spinlock acquisition before per-CPU access would make `preempt_disable()` unnecessary in the RT tree; the thread exposed several drivers that accessed per-CPU data without any lock, which the proposed Lockdep extension would have caught.
