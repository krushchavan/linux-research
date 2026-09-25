---
title: "Interrupt Handling and Locking"
category: concept
tags: [interrupts, locking, hardirq, softirq, spinlock, irq_desc]
subsystem: locking
kernel_version: "2.6.x (generic IRQ layer); threaded IRQs v2.6.30+; IRQF_DISABLED removed v3.1"
researched: 2026-04-12
status: complete
explained: "[[interrupt-handling-explained]]"
sources:
  - https://static.lwn.net/kerneldoc/core-api/genericirq.html
  - https://static.lwn.net/kerneldoc/kernel-hacking/locking.html
  - https://www.kernel.org/doc/html/v5.8/locking/locktypes.html
  - https://lwn.net/Articles/302043/
  - https://lwn.net/Articles/364583/
  - https://lwn.net/Articles/429690/
  - https://lwn.net/Articles/768157/
  - https://linux-kernel-labs.github.io/refs/heads/master/lectures/interrupts.html
  - https://0xax.gitbooks.io/linux-insides/content/Interrupts/linux-interrupts-9.html
  - https://kernel-internals.org/locking/
  - https://kernel-internals.org/interrupts/
  - https://archive.kernel.org/oldlinux/htmldocs/kernel-locking/hardirq-context.html
---

# Interrupt Handling and Locking

> 📘 Plain-language version: [[interrupt-handling-explained]]

## Purpose

Hardware devices signal the CPU asynchronously — a packet arrives, a disk read completes, a timer fires. Without a well-defined interrupt handling model, kernel data structures accessed from both normal code and interrupt handlers would be perpetually at risk of corruption. The interrupt handling subsystem defines a hierarchy of execution contexts, each with precise rules about what locks may be held and what sleeping is permitted, so that concurrency between hardware events and regular kernel execution can be reasoned about systematically.

## Mental Model

Think of the kernel as having a stack of execution contexts, each able to preempt the one below it. Process context sits at the bottom and can sleep. Softirq context sits above it and cannot sleep. Hardirq context sits above that, runs with local interrupts disabled, and must finish in microseconds. NMI context sits at the very top — it interrupts everything, including interrupt handlers, and can use almost no kernel services. Every locking primitive is stamped with the lowest context level from which it can safely be acquired; using the wrong primitive in the wrong context is the root cause of most interrupt-related deadlocks.

## How It Works

### Entry: From Hardware to `handle_irq()`

When a hardware device asserts an interrupt line, the CPU suspends the currently running thread, saves its register state on the interrupted stack or an interrupt stack (architecture-dependent), and jumps to a low-level assembly stub. That stub increments the per-CPU hardirq nesting counter (tracked in `preempt_count`) and calls into the generic IRQ layer via `desc->handle_irq(desc)`.

The `irq_desc` is the kernel's per-interrupt descriptor, allocated in `kernel/irq/irqdesc.c`. Each Linux IRQ number has exactly one `irq_desc`. The critical fields are:

```c
struct irq_desc {
    struct irq_data         irq_data;   /* per-irq chip-level data */
    irq_flow_handler_t      handle_irq; /* flow handler (level, edge, fasteoi…) */
    struct irqaction       *action;     /* linked list of registered handlers */
    raw_spinlock_t          lock;       /* protects this descriptor */
    unsigned int            status_use_accessors;
    unsigned int            depth;      /* disable depth */
    unsigned int            irqs_unhandled;
    …
};
```

`desc->lock` is a `raw_spinlock_t` — the interrupt-safe primitive that never sleeps and survives PREEMPT_RT unchanged. The generic layer holds `desc->lock` around flow-handler and chip operations, but the individual device driver handler (`action->handler`) runs *without* `desc->lock` held — the lock is dropped before calling into driver code so that handlers can re-enable interrupts and do real work.

### Flow Handlers: Matching Hardware Behavior

The flow handler sitting in `desc->handle_irq` is chosen at IRQ setup time based on the electrical characteristics of the interrupt line:

- **`handle_level_irq()`** — for level-triggered lines. Masks the interrupt before calling handlers, unmasks after. Necessary because a level interrupt will keep re-firing until the device is serviced, so the mask prevents a flood while the handler runs.
- **`handle_edge_irq()`** — for edge-triggered lines. Does not mask; instead detects whether a second edge arrived during handler execution (stored in the `IRQS_PENDING` status bit) and re-calls the handler if so. Masking an edge interrupt risks missing the edge entirely on hardware that lacks edge storage.
- **`handle_fasteoi_irq()`** — for modern interrupt controllers (e.g., x86 APIC) that just need an end-of-interrupt signal. Minimal masking overhead.
- **`handle_percpu_irq()`** — for per-CPU interrupts (e.g., local timer). No locking needed since each CPU has its own descriptor.

This split is a deliberate separation of concerns: the flow handler knows the electrical protocol; the chip's `irq_chip` callbacks know the register-level operations. The two compose without tangling.

### `irq_chip`: Chip-Level Operations

The `irq_chip` structure contains function pointers for the interrupt controller hardware:

```c
struct irq_chip {
    const char  *name;
    void        (*irq_ack)(struct irq_data *);
    void        (*irq_mask)(struct irq_data *);
    void        (*irq_unmask)(struct irq_data *);
    void        (*irq_eoi)(struct irq_data *);
    int         (*irq_set_affinity)(struct irq_data *, const struct cpumask *, bool);
    int         (*irq_set_type)(struct irq_data *, unsigned int flow_type);
    …
};
```

The locking of chip registers is the responsibility of the architecture providing the chip primitives. The generic layer only guarantees that `desc->lock` is held when it calls chip methods from within a flow handler.

### The `irqaction` Chain and Driver Handlers

Each call to `request_irq()` appends an `irqaction` to `desc->action`:

```c
struct irqaction {
    irq_handler_t       handler;    /* the driver's top-half */
    void               *dev_id;     /* cookie for disambiguation on shared lines */
    irq_handler_t       thread_fn;  /* threaded bottom half, if any */
    struct task_struct *thread;     /* kernel thread for thread_fn */
    struct irqaction   *next;       /* next handler on shared IRQ */
    unsigned int        flags;      /* IRQF_SHARED, IRQF_TRIGGER_*, … */
    …
};
```

On a shared IRQ line, all handlers in the chain are invoked sequentially; each returns `IRQ_HANDLED` or `IRQ_NONE` to indicate whether it owned the interrupt. The handler runs in hardirq context: interrupts are disabled on the local CPU, the hardirq nesting count is non-zero (`in_irq()` returns true), and sleeping is forbidden.

### Execution Context Hierarchy and Locking Rules

The execution contexts form a strict preemption hierarchy, and each pair of contexts that can share data requires a specific locking strategy:

| Context accessing shared data | Minimum lock variant |
|---|---|
| Process ↔ Softirq | `spin_lock_bh()` / `spin_unlock_bh()` |
| Process ↔ Hardirq | `spin_lock_irqsave()` / `spin_unlock_irqrestore()` |
| Softirq ↔ Hardirq | `spin_lock_irq()` / `spin_unlock_irq()` |
| Hardirq ↔ Hardirq (different IRQs) | `spin_lock_irqsave()` |
| NMI ↔ anything | Only `raw_spinlock_t` with extreme care; most kernel services are off-limits |

**Why `spin_lock_bh()`?** A softirq can preempt process context at any `local_bh_enable()` call site. If process context holds a plain spinlock and a softirq fires on the same CPU wanting the same lock, the softirq spins forever while the process context cannot run — a single-CPU deadlock. `spin_lock_bh()` calls `local_bh_disable()` first, preventing the softirq from ever preempting the critical section.

**Why `spin_lock_irqsave()` not `spin_lock_irq()`?** `spin_lock_irq()` unconditionally enables interrupts on release (`spin_unlock_irq()`), which is wrong if the caller was already in an interrupt-disabled region. `spin_lock_irqsave()` records the current flags (interrupt enable state) before disabling and restores them on release — safe to call from both softirq and hardirq contexts.

**Why not `spin_lock_irq()` in a hardirq handler?** Inside a hardware IRQ handler, interrupts are already disabled. Using `spin_lock_irq()` here is technically correct (disabling already-disabled interrupts is a no-op on x86), but on some architectures the behavior differs. `spin_lock_irqsave()` is always safe and is the recommended form when sharing between different hardirq handlers.

### The Bottom-Half Layer

Because hardware interrupt handlers must be brief (they run with interrupts disabled), most actual work is deferred to bottom halves. There are three mechanisms, in decreasing order of interrupt-context proximity:

**Softirqs** are statically defined (up to 32 vectors, 10 in use) and run immediately after a hardirq handler returns, in a brief `do_softirq()` loop. The `__softirq_pending` per-CPU bitmask tracks which vectors are raised; `raise_softirq()` sets a bit atomically using `local_irq_save/restore`. Softirqs of the *same* type can run in parallel on different CPUs — `NET_RX_SOFTIRQ` might run on CPU 0 and CPU 1 simultaneously, which is why networking code uses per-CPU variables or RCU rather than a single lock.

If `do_softirq()` keeps firing (device storm or runaway timer), the kernel allows at most `MAX_SOFTIRQ_RESTART` consecutive rounds, then wakes `ksoftirqd/<cpu>` — a per-CPU kernel thread that drains the remaining softirq backlog in a schedulable context, allowing the CPU to run other tasks.

**Tasklets** are built on top of softirqs (TASKLET_SOFTIRQ and HI_SOFTIRQ vectors). Unlike softirqs, a given tasklet is serialized: the same tasklet cannot run on two CPUs simultaneously. The `tasklet_trylock()` mechanism sets `TASKLET_STATE_RUN` with an atomic cmpxchg; if the bit is already set on another CPU, the tasklet is re-queued. This makes tasklets easier to use than raw softirqs — no multi-CPU reentrancy to handle — at the cost of some parallelism.

**Workqueues** run in process context via `kworker` kernel threads. This makes blocking operations (memory allocation with `GFP_KERNEL`, mutex locks, `msleep()`) legal. The concurrency-managed workqueue (cmwq) framework dynamically scales the number of worker threads per CPU based on saturation: if all workers are sleeping, a new one is created; excess workers are retired. Because workqueue handlers run in process context, they use ordinary sleeping locks and have no special interrupt-context locking requirements.

### Threaded IRQs

`request_threaded_irq()` separates a driver's interrupt handling into a quick top-half check function and a full handler that runs in a dedicated kernel thread:

```c
int request_threaded_irq(unsigned int irq,
                         irq_handler_t handler,      /* hardirq: quick check */
                         irq_handler_t thread_fn,    /* kthread: real work */
                         unsigned long flags,
                         const char *name, void *dev);
```

The quick `handler` runs in hardirq context, confirms the interrupt is from this device, and returns `IRQ_WAKE_THREAD`. The kernel then wakes the associated `irq/<n>-<name>` thread, which runs `thread_fn` in a fully schedulable, preemptible context — it can sleep, take mutexes, and call any kernel service.

The primary motivation is **simplicity**: threaded handlers eliminate the need to coordinate between a hardirq top half and a tasklet or workqueue bottom half. Instead of three pieces of code with three different lock requirements, there are two functions with two well-understood contexts. The PREEMPT_RT patchset pioneered this approach, where nearly all interrupt handlers were converted to threads to achieve deterministic latency; `threadirqs` on the kernel command line replicates this on non-RT kernels.

### PREEMPT_RT Semantic Changes

Under `CONFIG_PREEMPT_RT`, `spinlock_t` and `rwlock_t` become sleeping locks (backed by `rt_mutex`). This means the `_irq` and `_irqsave/_irqrestore` suffix variants no longer affect the CPU's interrupt disabled state — disabling hardware interrupts for long periods would negate RT latency guarantees. However, `_bh()` variants still disable softirq processing because that context dependency is preserved.

Code that must be safe even under PREEMPT_RT must use `raw_spinlock_t` with `_irqsave()` variants; `raw_spinlock_t` is never converted to a sleeping lock. This is why the interrupt descriptor's `desc->lock` is a `raw_spinlock_t` — it is taken from hardirq context where sleeping is impossible regardless of kernel configuration.

## Key Data Structures

**`struct irq_desc`** (`include/linux/irqdesc.h`) — per-Linux-IRQ descriptor; the root of interrupt metadata.
- `irq_data` — contains `hwirq` (hardware number), `chip`, `domain`, and chip-private data
- `handle_irq` — the flow handler (level/edge/fasteoi/…)
- `action` — head of the `irqaction` chain (one entry per `request_irq()`)
- `lock` — `raw_spinlock_t` protecting this descriptor
- `depth` — disable nesting counter; IRQ is re-enabled only when this reaches 0

**`struct irqaction`** (`include/linux/interrupt.h`) — one registered handler.
- `handler` — top-half function, runs in hardirq context
- `thread_fn` / `thread` — threaded bottom-half and its kernel task
- `flags` — `IRQF_SHARED`, `IRQF_TRIGGER_*`, `IRQF_NO_THREAD`
- `dev_id` — disambiguates handlers on shared IRQ lines

**`struct irq_chip`** (`include/linux/irq.h`) — controller-side operations table.
- `irq_mask` / `irq_unmask` / `irq_ack` / `irq_eoi` — wired to hardware register writes

**`softirq_action`** (`include/linux/interrupt.h`) — one entry in the static `softirq_vec[NR_SOFTIRQS]` array.
- `action` — function pointer invoked by `do_softirq()`

**`struct tasklet_struct`** (`include/linux/interrupt.h`) — dynamically allocated deferred work serialized per-tasklet.
- `state` — `TASKLET_STATE_SCHED` (queued) / `TASKLET_STATE_RUN` (executing)
- `count` — disable count (tasklet is skipped if non-zero)
- `callback` — the function to call

## Key Functions / Entry Points

**`request_irq()` / `request_threaded_irq()`** (`kernel/irq/manage.c`) — allocate an `irqaction`, attach it to `desc->action`, enable the IRQ line via `irq_chip.irq_startup()`.

**`handle_level_irq()` / `handle_edge_irq()` / `handle_fasteoi_irq()`** (`kernel/irq/chip.c`) — flow handlers called from `desc->handle_irq()`; manage mask/ack/eoi around driver handler invocation.

**`__do_softirq()`** (`kernel/softirq.c`) — drains pending softirq vectors; called at hardirq exit, at `local_bh_enable()`, and by `ksoftirqd`; bounded by `MAX_SOFTIRQ_TIME` and `MAX_SOFTIRQ_RESTART`.

**`raise_softirq()` / `raise_softirq_irqoff()`** (`kernel/softirq.c`) — sets a bit in `__softirq_pending` to mark a vector pending; `raise_softirq()` saves/restores irq flags around the operation.

**`tasklet_schedule()` / `tasklet_hi_schedule()`** (`kernel/softirq.c`) — add a tasklet to the per-CPU `tasklet_vec` / `tasklet_hi_vec` list and raise the appropriate softirq.

**`local_irq_disable()` / `local_irq_enable()`** (`arch/*/include/asm/irqflags.h`) — direct CPU-level interrupt flag manipulation; should rarely appear in driver code (use `spin_lock_irqsave()` instead).

**`local_bh_disable()` / `local_bh_enable()`** (`kernel/softirq.c`) — increment/decrement the per-CPU softirq disable counter; `local_bh_enable()` triggers `do_softirq()` if any vectors are pending.

**`disable_irq()` / `enable_irq()`** (`kernel/irq/manage.c`) — increment/decrement `desc->depth`; mask the hardware line when depth goes positive. `disable_irq()` waits for any currently executing handler to complete before returning.

**`synchronize_irq()`** (`kernel/irq/manage.c`) — waits until no handler for the given IRQ is currently executing; used before freeing shared data.

## Important Flags & Config Options

**`IRQF_SHARED`** — allows multiple devices to share a single IRQ line; each `irqaction.handler` is called in turn.

**`IRQF_NO_THREAD`** — prevents the handler from being forced into a thread by `threadirqs` on the command line. Use for handlers that are extremely fast or that cannot tolerate the scheduling overhead.

**`IRQF_TRIGGER_*`** (`IRQF_TRIGGER_RISING`, `IRQF_TRIGGER_LEVEL_HIGH`, …) — configure the electrical triggering mode; passed to `irq_chip.irq_set_type()`.

**`CONFIG_PREEMPT_RT`** — converts `spinlock_t` to a sleeping lock; `_irq` suffixes no longer disable hardware interrupts; forces nearly all interrupt handlers to threads. Dramatically simplifies locking reasoning in drivers at the cost of slightly higher per-interrupt overhead.

**`CONFIG_SPARSE_IRQ`** — allocates `irq_desc` structures on demand (radix tree) rather than as a static array. Essential on systems with large, sparse hardware IRQ number spaces (e.g., ARM GIC with thousands of potential IRQs).

**`threadirqs`** (kernel command line) — forces all handlers (except those with `IRQF_NO_THREAD`) to run as kernel threads. Useful for debugging and RT-like behavior without a full PREEMPT_RT build.

## Interactions with Other Subsystems

- **↑ Userspace**: `signalfd`, `epoll`, and `io_uring` ultimately dispatch work triggered by hardirq→softirq→workqueue chains; none of the interrupt infrastructure is directly visible to userspace.
- **→ [[scheduler]]**: `ksoftirqd` and threaded IRQ threads are ordinary kernel threads scheduled by CFS/RT; raising a softirq can indirectly cause a wakeup of `ksoftirqd`, feeding back into the scheduler's run queue.
- **→ [[rcu-read-copy-update]]**: RCU has its own softirq vector (RCU_SOFTIRQ) for quiescent-state callbacks. `raise_softirq(RCU_SOFTIRQ)` is the mechanism by which RCU transitions work to a deferrable context.
- **→ [[per-cpu-variables]]**: Softirq pending bitmasks, tasklet queues, and most interrupt statistics are per-CPU variables, allowing lockless access from interrupt context on the local CPU.
- **← [[seqlocks-and-memory-barriers]]**: `local_irq_save/restore` implicitly includes compiler barriers; explicit memory barriers (`smp_mb()`) are still required when ordering stores visible to interrupt handlers against stores visible to remote CPUs.
- **← block / networking**: The BLOCK and NET_TX/NET_RX softirq vectors are the primary consumers of softirq bandwidth; the interrupt model directly constrains the throughput and latency of I/O paths.

## Design Decisions & Tradeoffs

**Why a three-level (hardirq / softirq / process) model rather than just threads?**
Hardirq context guarantees bounded entry latency for time-critical acknowledgment (mask the device before a second interrupt fires, copy from a DMA buffer before it's overwritten). Softirq context allows batched processing at interrupt-exit with less overhead than scheduling a kernel thread. Full threads add scheduling latency but support sleeping. The three-level hierarchy matches the three classes of work: microsecond-critical, batch-efficient, and complex.

**Why were `tasklets` built on top of softirqs rather than as a separate mechanism?**
Tasklets reuse the softirq infrastructure (raised bitmask, `do_softirq()` drain, `ksoftirqd` fallback) and add only a serialization layer on top. This kept the kernel simple: one deferred-work drain path, two runnable abstraction levels.

**Why was `IRQF_DISABLED` removed (v3.1)?**
`IRQF_DISABLED` was supposed to mean "run this handler with interrupts disabled," but by 2.6.x all handlers already ran with local interrupts disabled, making the flag a no-op. Worse, on shared IRQ lines the flag had no effect if any other handler on the line hadn't set it. Peter Zijlstra's removal patch (LWN: *Eliminating rwlocks and IRQF_DISABLED*) cleaned up a long-standing source of confusion about interrupt handler guarantees.

**Why does the generic IRQ layer separate flow handlers from chip primitives?**
Earlier architectures (pre-2.6.18 generic IRQ) interleaved edge/level logic with hardware register writes, meaning every new interrupt controller required re-implementing the flow logic. The Thomas Gleixner / Ingo Molnár rewrite of the IRQ subsystem (introduced ~2.6.18) separated the two, allowing architectures to pick a generic flow handler (level, edge, fasteoi) and implement only a small `irq_chip` table. This enabled the same driver to work on multiple SoC interrupt controllers without modification.

## How It Has Evolved

**Pre-2.6.18 (architecture-specific interrupt handling)**: Each architecture had its own `do_IRQ()` implementation tightly coupled to its interrupt controller. Adding support for a new controller often required forking code.

**2.6.18 (generic IRQ layer)**: Thomas Gleixner and Ingo Molnár introduced the three-level `irq_chip` / flow handler / driver API model. Architectures began migrating to the generic layer, and the `irq_domain` library soon followed to abstract hardware-to-Linux IRQ number mapping.

**2.6.30 (threaded IRQs)**: `request_threaded_irq()` was merged, originally prototyped in the PREEMPT_RT tree. This was the first step toward moving interrupt handler complexity out of the hardirq fast path.

**3.1 (IRQF_DISABLED removal)**: The flag became a formal no-op and was removed, acknowledging that all handlers already ran with IRQs disabled.

**3.x (forced threaded IRQs / `threadirqs`)**: The command-line option to force all handlers to threads was added, closing the gap between PREEMPT_RT and mainline for experimentation.

**5.x (PREEMPT_RT merged incrementally)**: Pieces of the RT patchset landed in mainline — `local_lock`, `raw_spinlock_t` semantics, and eventually `CONFIG_PREEMPT_RT` itself in 5.15. On RT kernels, interrupt handling locking is fundamentally different: `spinlock_t` sleeps, and the `_irq` variants do not disable hardware interrupts.

## Further Reading

1. [Unreliable Guide To Locking — kernel.org](https://static.lwn.net/kerneldoc/kernel-hacking/locking.html) — authoritative guide to context-aware locking
2. [Linux generic IRQ handling — kernel.org](https://static.lwn.net/kerneldoc/core-api/genericirq.html) — the official generic IRQ layer documentation
3. [Lock types and their rules — kernel.org](https://www.kernel.org/doc/html/v5.8/locking/locktypes.html) — PREEMPT_RT semantics for every lock type
4. [Moving interrupts to threads — LWN](https://lwn.net/Articles/302043/) — Thomas Gleixner's threaded IRQ proposal and rationale
5. [Eliminating rwlocks and IRQF_DISABLED — LWN](https://lwn.net/Articles/364583/) — history of IRQF_DISABLED removal
6. [Software interrupts and realtime — LWN](https://lwn.net/Articles/520076/) — softirq execution model and RT implications
7. [Local locks in the kernel — LWN](https://lwn.net/Articles/828477/) — `local_lock` as a PREEMPT_RT-safe per-CPU primitive
8. [Heuristics for software-interrupt processing — LWN](https://lwn.net/Articles/925540/) — modern softirq throttling and ksoftirqd tuning
9. [Linux Interrupts — linux-kernel-labs](https://linux-kernel-labs.github.io/refs/heads/master/lectures/interrupts.html) — lecture slides with diagrams of all contexts

## LKML Highlights

- **Threaded IRQ introduction (2009)**: Thomas Gleixner's series adding `request_threaded_irq()` and the `threadirqs` boot option. The thread debated whether the PREEMPT_RT approach (all IRQs threaded by default) should go mainline versus opt-in. The opt-in approach won. See LWN coverage at https://lwn.net/Articles/302043/.

- **IRQF_DISABLED removal (2010-2011)**: Peter Zijlstra proposed making the flag a no-op and then removing it entirely. The discussion clarified that architectures had been quietly enforcing IRQ-disabled handlers for years; the flag had become a documentation lie. https://lwn.net/Articles/364583/

- **Per-vector softirq masking (2018)**: A proposal by Sebastian Andersen to add per-vector `disable_softirq()` analogous to `disable_irq()`, enabling drivers to suppress specific softirq vectors. The discussion revealed how deeply kernel subsystems had come to depend on implicit softirq exclusion semantics, and the patch was ultimately declined in that form. https://lwn.net/Articles/779738/
