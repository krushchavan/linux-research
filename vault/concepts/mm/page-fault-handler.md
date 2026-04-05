---
title: "Page Fault Handler"
category: concept
tags: [memory, mm, page-fault, mmu, demand-paging, cow]
subsystem: mm
kernel_version: "1.0+"
researched: 2026-04-05
status: complete
sources:
  - https://kernel-internals.org/mm/page-fault/
  - https://www.kernel.org/doc/html/latest/mm/page_tables.html
  - https://lwn.net/Articles/906852/
  - https://lwn.net/Articles/550555/
  - https://lwn.net/Articles/754739/
---

# Page Fault Handler

## Purpose

The page fault handler is the runtime engine that makes demand paging work. When the CPU tries to access a virtual address with no PTE, a write-protected page, or a swapped-out page, the MMU raises a hardware exception and hands control to the kernel. The handler's job is to distinguish *expected* faults (anonymous pages being touched for the first time, COW breaks, swap-ins) from *illegal* accesses (segfaults, kernel bugs) and to resolve the former without the process ever noticing a pause — other than latency.

Without the fault handler, every page would need to be allocated and mapped at `mmap()` time. Instead, the kernel can return a virtual address instantly and defer all the physical memory work until the moment it is actually needed.

## Mental Model

Think of virtual addresses as promises. `mmap()` writes a promise — "this range is yours" — but nothing is delivered yet. The page fault handler is the delivery service: the moment you try to actually *use* a promised address, the handler rushes to fulfil it. A read on a fresh anonymous page delivers a shared zero page (cheap). A write on that same page triggers a fresh delivery of a dedicated copy. A write on a COW page after `fork()` means two processes claimed the same promise — the handler makes a copy and hands each process their own. A swap-in is a delivery from long-term storage. The handler handles all these cases and then returns the CPU to the instruction that faulted, which re-executes successfully as if nothing happened.

## How It Works

**Hardware handoff.** On x86, when the MMU cannot translate a virtual address — because the PTE is not-present, a write hits a read-only PTE, or an instruction fetch violates NX — the CPU raises exception #14 (Page Fault), saves the faulting virtual address in CR2, and encodes context into a 32-bit error code:

- **Bit 0 (P)**: 0 = page not present, 1 = protection violation (write to RO, NX)
- **Bit 1 (W)**: 0 = read, 1 = write
- **Bit 2 (U)**: 0 = kernel mode, 1 = user mode
- **Bit 4 (I)**: 1 = instruction fetch (NX violation)

The IDT entry for #14 jumps to `exc_page_fault()` (`arch/x86/mm/fault.c`). This function reads CR2, saves fault context into a `struct pt_regs`, and forwards to `handle_page_fault()`.

**Kernel vs. user space split.** `handle_page_fault()` branches immediately:
- **Kernel address**: `do_kern_addr_fault()` — handles vmalloc synchronisation faults (a new kernel mapping that hasn't yet been propagated to all CPUs' PGDs), and looks up the kernel's exception tables for expected faults (`copy_to/from_user`). If neither applies, it's a kernel bug → `oops`.
- **User address**: `do_user_addr_fault()` — the main path for all user-space memory access.

**VMA lookup and validation.** `do_user_addr_fault()` needs to find the VMA covering the faulting address. Since v6.4 it tries the fast path first: `lock_vma_under_rcu(mm, addr)` acquires the per-VMA seqlock without taking `mmap_lock`. If the seqcount is unchanged since the RCU lock (meaning no concurrent structural change), the fault proceeds under just the VMA lock. If the seqcount changed or the VMA can't be found under RCU, the path falls back to `mmap_lock` in read mode and a full `find_vma()` maple-tree lookup.

Once the VMA is found, permissions are checked: a write fault on a read-only VMA (`!(vma->vm_flags & VM_WRITE)`) → `SIGSEGV`; a fault below the stack VMA that qualifies for stack growth → `expand_stack()`. Otherwise, control passes to `handle_mm_fault()`.

**`handle_mm_fault()` and `__handle_mm_fault()`.** `handle_mm_fault()` (`mm/memory.c`) increments fault statistics and calls `__handle_mm_fault()`, which walks the page table hierarchy to the correct PMD (allocating intermediate tables as needed), then calls `handle_pte_fault()` on the leaf PTE.

**`handle_pte_fault()` dispatch.** This function reads the PTE and dispatches to the right sub-handler:

| PTE state | Condition | Handler |
|-----------|-----------|---------|
| Not present, no swap entry | Anonymous VMA | `do_anonymous_page()` |
| Not present, no swap entry | File-backed VMA | `do_fault()` → `filemap_fault()` |
| PTE has swap entry | Swapped out | `do_swap_page()` |
| Present but write-protected | Write fault, COW needed | `do_wp_page()` |

**Anonymous faults — `do_anonymous_page()`.** On a *read* fault, the kernel maps the shared `ZERO_PAGE` (a single physical page of zeros shared across the entire system) with a read-only PTE. No physical allocation; cost is one TLB entry. On a *write* fault (or when the read fault has to be upgraded), `alloc_zeroed_user_highpage_movable()` allocates a fresh page from the buddy allocator, fills it with zeros (or relies on `GFP_ZERO` allocation), and installs a writable PTE. This is demand-zero allocation: the physical page only appears when the process actually touches a byte.

**File-backed faults — `do_fault()`.** When the faulting VMA has a `vm_file` and no PTE yet, `do_fault()` routes to one of:
- **`do_read_fault()`** — read access; calls `vm_ops->fault()` which calls `filemap_fault()`. This checks the page cache for the needed folio at `vm_pgoff + fault_offset`. If present, it pins the folio and installs a read-only PTE. If absent, `filemap_fault()` triggers readahead (possibly bringing in several surrounding pages) and blocks until the I/O completes — this is a *major fault* (`VM_FAULT_MAJOR`).
- **`do_cow_fault()`** — write fault on a `MAP_PRIVATE` file mapping. Allocates a new page, populates it via `filemap_fault()`, copies the content, then installs a writable PTE pointing to the new private page. The file's page cache is untouched.
- **`do_shared_fault()`** — write fault on a `MAP_SHARED` file mapping. Calls `filemap_fault()` to bring the page into the page cache, then marks it dirty via `vm_ops->page_mkwrite()`, and installs a writable PTE. The write will eventually reach the file via writeback.

**COW faults — `do_wp_page()`.** A write fault on a present-but-read-only PTE triggers copy-on-write. `do_wp_page()` checks the page's reference count:
- **`wp_page_reuse()`**: If this process is the only reference holder (`page_count == 1`), the page can be made writable in-place — just flip the PTE to writable. No copy needed.
- **`wp_page_copy()`**: Multiple holders (typical after `fork()`). Allocates a new page, copies the content with `copy_user_highpage()`, decrements the old page's refcount, and installs a new writable PTE pointing to the copy. The parent still has its read-only PTE pointing to the original page; the child now has its own writable copy.

**Swap-in faults — `do_swap_page()`.** When the PTE contains a swap entry (`is_swap_pte()` is true), `do_swap_page()` decodes the `swp_entry_t` to find the swap type (device) and offset. It first checks the *swap cache* — a radix/XArray structure that holds pages in transit between swap and RAM. A swap-cache hit avoids device I/O entirely. On a miss, it reads the page from the swap device via `swap_readpage()` (a `submit_bio()` call), waits for completion, and installs the PTE. The page stays in the swap cache briefly in case another process faults on the same entry.

**Return value: `vm_fault_t`.** All fault sub-handlers return a `vm_fault_t` bitmask. Common bits:
- `VM_FAULT_OOM` — allocation failed; trigger OOM killer
- `VM_FAULT_SIGBUS` — invalid access for this mapping type
- `VM_FAULT_MAJOR` — I/O was required (counted in `/proc/<pid>/stat`)
- `VM_FAULT_RETRY` — per-VMA lock couldn't be acquired; retry with mmap_lock
- `VM_FAULT_NOPAGE` — fault handled but no PTE installed (e.g. NUMA migration)

On `VM_FAULT_RETRY`, the kernel releases the per-VMA lock and retries the entire fault with `mmap_lock` in read mode, picking up from `handle_mm_fault()`.

**Kernel exception recovery.** For faults that happen inside `copy_to/from_user()` and friends, the kernel registers a *fixup* in `__ex_table`. If a fault occurs at an address listed there, `fixup_exception()` patches the return address to a recovery stub that returns `-EFAULT` to the caller rather than killing the kernel. This is how safe user-space access functions handle bad user pointers without crashing.

## Key Data Structures

**`struct vm_fault`** (`include/linux/mm_types.h`) — populated by `handle_mm_fault()` and passed to all sub-handlers and `vm_ops->fault()`.
- `vma` — the VMA covering the faulting address
- `address` — the page-aligned faulting virtual address
- `flags` — `FAULT_FLAG_WRITE`, `FAULT_FLAG_USER`, `FAULT_FLAG_RETRY_NOWAIT`, `FAULT_FLAG_VMA_LOCK`
- `pmd` / `pte` — pointers into the page table hierarchy, pre-walked by `__handle_mm_fault()`
- `page` — the physical page to install (set by sub-handler, used to build the PTE)
- `cow_page` — freshly allocated COW destination page
- `pgoff` — page offset within the file (for file-backed faults)
- `orig_pte` — snapshot of the PTE before locking (used to detect races)

**`struct mm_struct`** — see [[virtual-memory-areas]]; the fault handler reads `mm->mm_mt` (VMA maple tree) and `mm->mmap_lock`.

**`struct vm_area_struct`** — see [[virtual-memory-areas]]; the fault handler reads `vm_flags`, `vm_ops`, `vm_file`, and `vm_pgoff` to determine which sub-handler to call.

## Key Functions / Entry Points

**`exc_page_fault(regs, error_code)`** (`arch/x86/mm/fault.c`) — architecture entry point; reads CR2, dispatches kernel/user.

**`do_user_addr_fault(regs, hw_error_code, address)`** (`arch/x86/mm/fault.c`) — VMA lookup (per-VMA lock or mmap_lock), permission check, calls `handle_mm_fault()`.

**`handle_mm_fault(vma, address, flags, regs)`** (`mm/memory.c`) — public entry point; updates fault stats, calls `__handle_mm_fault()`.

**`__handle_mm_fault(vma, address, flags)`** (`mm/memory.c`) — walks page table levels (allocating as needed), calls `handle_pte_fault()`.

**`handle_pte_fault(vmf)`** (`mm/memory.c`) — dispatch: reads PTE state and calls the correct sub-handler.

**`do_anonymous_page(vmf)`** (`mm/memory.c`) — demand-zero anonymous fault; maps zero page (read) or allocates new zeroed page (write).

**`do_fault(vmf)`** (`mm/memory.c`) — file-backed fault; routes to `do_read_fault`, `do_cow_fault`, or `do_shared_fault`.

**`do_wp_page(vmf)`** (`mm/memory.c`) — COW write fault; reuse in-place or allocate-copy.

**`do_swap_page(vmf)`** (`mm/memory.c`) — swap-in; check swap cache, read from device, reinstall PTE.

**`lock_vma_under_rcu(mm, addr)`** (`mm/memory.c`) — fast per-VMA lock acquisition; returns `NULL` on failure.

## Important Flags & Config Options

| Flag / Config | Meaning |
|--------------|---------|
| `FAULT_FLAG_WRITE` | Fault was caused by a write access |
| `FAULT_FLAG_USER` | Fault occurred in user mode |
| `FAULT_FLAG_RETRY_NOWAIT` | Do not sleep on I/O; return `VM_FAULT_RETRY` instead |
| `FAULT_FLAG_VMA_LOCK` | Fault is being handled under a per-VMA lock (not mmap_lock) |
| `VM_FAULT_OOM` | Fault handler couldn't get memory; OOM path |
| `VM_FAULT_MAJOR` | Page was loaded from I/O; counted as major fault |
| `VM_FAULT_RETRY` | Retry needed; lock state changed during handling |
| `CONFIG_USERFAULTFD` | Enables userspace fault handling; adds `userfaultfd_ctx` to VMA |

## Interactions with Other Subsystems

- **← VMA / [[virtual-memory-areas]]**: The fault handler reads the VMA to determine what backing the faulting address has, and uses the per-VMA lock (v6.4+) to avoid `mmap_lock` contention.
- **→ [[buddy-allocator]] / [[slub-slab-allocator]]**: Anonymous and COW paths call `alloc_page()` / `alloc_zeroed_user_highpage_movable()` to get a physical page.
- **→ [[page-cache]]**: File-backed fault paths call `filemap_fault()` to look up or load the needed folio from the page cache; a miss triggers read I/O.
- **→ [[swap]]**: Swap-in path calls `do_swap_page()`, which accesses the swap cache and swap device.
- **↓ Hardware MMU**: The fault handler installs PTEs via `set_pte_at()`. The MMU's TLB caches these entries; after installation the retried instruction completes without a fault.
- **← `fork()` / COW**: `fork()` marks all anonymous pages read-only in both parent and child. The first write in either process triggers `do_wp_page()` to make a private copy.
- **→ [[page-reclaim]]**: On `VM_FAULT_OOM`, the OOM killer is invoked to free memory.

## Design Decisions & Tradeoffs

**Demand paging over pre-population.** Allocating pages only on first access makes `mmap()` and `fork()` O(1) operations. A freshly `fork()`ed process copies only VMA descriptors, not pages. The cost is per-page latency on first access and increased kernel complexity (the fault handler must handle all the cases that eager allocation would have handled at setup time).

**Shared zero page for anonymous reads.** Rather than allocating a zeroed page for every `mmap()`ed byte that is read before written (e.g. BSS variables that are never modified), the kernel maps all such reads to a single shared physical page of zeros. The COW mechanism ensures the first write to any such page allocates a private copy. This saves enormous amounts of physical memory for processes with large zeroed BSS regions.

**Per-VMA locks over mmap_lock (v6.4).** The `mmap_lock` was a global per-process rwsem; all concurrent page faults in a process serialised on it. Per-VMA locks add a seqlock to each `vm_area_struct`, allowing faults on different VMAs to proceed in parallel. The cost: extra complexity (the `VM_FAULT_RETRY` path), and the overhead of checking the seqcount on every fault. The gain: `mmap_lock` usage in the fault path dropped to near zero on multi-threaded workloads.

**`vm_fault_t` return type.** Before v4.17, `vm_ops->fault()` returned an `int` but the expected values were a bitmask of `VM_FAULT_*` flags. This was confusing and error-prone (callers mixing it with `errno` values). The `vm_fault_t` typedef (added by Christoph Hellwig in v4.17) is a distinct integer type that forces the compiler to catch accidental returns of errno-style negative values.

## How It Has Evolved

| Version | Change | Driver |
|---------|--------|--------|
| Linux 1.0 | Basic fault handler: not-present, write-protection, swap-in | Demand paging foundation |
| v2.4 | VMA-based dispatch; `vm_ops->fault()` introduced | Generalise for file-backed mappings |
| v2.6 | Huge page fault paths, NUMA fault handling | Large-memory server workloads |
| v4.17 (2018) | `vm_fault_t` return type | Type safety; prevent errno/bitmask confusion |
| v6.1 (2022) | VMA lookup via maple tree | RCU-safe VMA lookup prerequisite |
| v6.4 (2023) | Per-VMA locks in fault path | Eliminate `mmap_lock` bottleneck on concurrent fault workloads |
| v6.6 (2023) | Per-VMA locks extended to swap and userfaultfd paths | More fault types bypass `mmap_lock` |

## Further Reading

1. [LWN — Concurrent page-fault handling with per-VMA locks](https://lwn.net/Articles/906852/) — design and motivation of the seqlock approach
2. [LWN — Speculative page faults](https://lwn.net/Articles/754739/) — earlier attempt at lockless fault handling; why it was harder than per-VMA locks
3. [LWN — User-space page fault handling (userfaultfd)](https://lwn.net/Articles/550555/) — intercepting and handling faults in userspace
4. [kernel.org — page_tables.rst](https://www.kernel.org/doc/html/latest/mm/page_tables.html) — page table hierarchy and PTE flag documentation

## LKML Highlights

- **[vm_fault_t type enforcement (Christoph Hellwig, 2018)](https://lore.kernel.org/all/20180516054348.15950-15-hch@lst.de/)** — the 14-patch series that turned `VM_FAULT_*` return values into a distinct type; the cover letter documents exactly where the `int`/bitmask confusion had caused real bugs and how a simple typedef catches them at compile time.
