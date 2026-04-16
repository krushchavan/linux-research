---
title: "BPF Maps"
category: concept
tags: [bpf, maps, data-structures, ipc, kernel-userspace]
subsystem: bpf
kernel_version: "3.18"
researched: 2026-04-16
status: complete
sources:
  - https://lwn.net/Articles/740157/
  - https://kernel-internals.org/bpf/
  - https://www.kernel.org/doc/html/latest/bpf/index.html
  - https://lwn.net/Articles/821456/
---

# BPF Maps

## Purpose

BPF programs execute inside the kernel in interrupt or softirq context and cannot call blocking syscalls. Yet they need to share state — counters, connection tables, event queues — both with userspace control planes and with other BPF programs. BPF maps are the sole structured mechanism for this: typed, reference-counted kernel data structures accessible from both sides of the kernel/userspace boundary through a single, verifier-audited API.

## Mental Model

A BPF map is a **kernel-managed shared memory object with a typed key-value API**. Think of it like a POSIX shared-memory segment, but with access from both userspace (via `bpf()` syscall) and kernel-space BPF programs (via helper function calls). The kernel enforces all bounds checking and, for some map types, concurrency control. The verifier guarantees that BPF programs never dereference map value pointers out of bounds.

## How It Works

A map is created with `BPF_MAP_CREATE`, specifying `map_type`, `key_size`, `value_size`, and `max_entries`. The kernel allocates backing memory (preallocated for array and hash maps, demand-allocated with `BPF_F_NO_PREALLOC`), initialises an ops vtable, and returns a file descriptor. The map is reference-counted: held by the fd, by any loaded BPF programs that use it, and by any bpffs pin at `/sys/fs/bpf/<path>`. When all references drop, the map is freed.

From a BPF program, the compiler generates a load-immediate of the map's BTF type ID, which the JIT translates to a direct pointer to the `struct bpf_map`. The helper call `bpf_map_lookup_elem(map, &key)` dispatches through `map->ops->map_lookup_elem()` and returns a pointer directly into the map's value memory — zero copy. The verifier tracks this pointer as `PTR_TO_MAP_VALUE` and validates every dereference against `value_size`.

From userspace, the `bpf()` syscall with `BPF_MAP_LOOKUP_ELEM` copies the key in from userspace, calls `map->ops->map_lookup_elem()`, and copies the result out to userspace. This copy-in/copy-out is the price of the userspace control path; the BPF program path is zero-copy.

### Map types

**`BPF_MAP_TYPE_ARRAY`** — the simplest: a flat C array of `max_entries` slots, each `value_size` bytes, zero-initialized and never freed. Key is a u32 index; lookup is O(1) by pointer arithmetic. Preallocated at map creation; no per-entry overhead. Ideal for per-CPU counters, histograms, and configuration tables. `BPF_MAP_TYPE_PERCPU_ARRAY` multiplies the backing store by `nr_cpu_ids`, giving each CPU its own slot — lookups return the per-CPU slice, eliminating any atomic or lock overhead for update-heavy scenarios.

**`BPF_MAP_TYPE_HASH`** — a hash table with `max_entries` buckets using RCU-safe chaining. Entries are dynamically allocated (via `kmalloc` or a per-map mempool). Supports arbitrary key types. `BPF_MAP_TYPE_LRU_HASH` adds an LRU eviction list so the map stays bounded without caller-side deletion — used for connection tracking where stale entries must be reclaimed automatically. `BPF_MAP_TYPE_PERCPU_HASH` gives each CPU its own value to avoid cross-CPU contention.

**`BPF_MAP_TYPE_LPM_TRIE`** — a longest-prefix-match trie over variable-length keys (`struct bpf_lpm_trie_key`). Used in XDP programs for IP routing and firewall allowlists where the packet's source address must match a CIDR prefix. Entries are sorted by prefix length; lookup walks the trie and returns the deepest match.

**`BPF_MAP_TYPE_PROG_ARRAY`** — stores BPF program file descriptors. A `bpf_tail_call(ctx, prog_array, index)` call *replaces* the current program's stack frame with the indexed program's frame, enabling zero-overhead trampolining between programs. Used to implement state machines (e.g. a multi-stage protocol parser) that would otherwise exceed the 1M-instruction verification limit in a single program.

**`BPF_MAP_TYPE_RINGBUF`** — a power-of-two-sized circular buffer backed by a contiguous physically-allocated region that is `mmap()`-ed read-only into userspace. The BPF program side calls `bpf_ringbuf_reserve(size)` to get a pointer to a free slot, writes into it, then `bpf_ringbuf_commit()`. The userspace side reads via `bpf_ring_buffer_poll()`. Because the physical pages are shared, there is no copy on the consumer path. A single ring buffer can be written by multiple CPUs simultaneously (a producer spinlock covers only the reservation step). See [[bpf-ring-buffer]] for detail.

**`BPF_MAP_TYPE_SOCKMAP` / `SOCKHASH`** — stores `struct sock *` pointers. `bpf_sk_redirect_map()` and `bpf_msg_redirect_map()` can forward packets directly between sockets without a userspace round-trip, implementing kernel-level proxy and load-balancing.

**`BPF_MAP_TYPE_ARRAY_OF_MAPS` / `HASH_OF_MAPS`** — nested maps: the outer map stores fds to inner maps. Enables atomic swap of an entire table by replacing the outer entry's fd.

### Concurrency

Hash maps use a per-bucket spinlock for update/delete operations, RCU read lock for lookups. Array maps use atomic operations for 64-bit values; wider values require `BPF_F_LOCK` (a `struct bpf_spin_lock` embedded at the start of the value). Per-CPU maps skip all locking by confining each CPU to its own slice.

The verifier enforces spin-lock discipline: it tracks which map value pointers have an associated lock held and rejects programs that dereference a lock-protected value without acquiring the lock first.

### BTF annotations

Maps created with BTF type IDs (`btf_key_type_id`, `btf_value_type_id`) link their key and value types to the kernel's BTF graph. `bpftool map dump` uses this to pretty-print records. kptr annotations (`__kptr`, `__kptr_ref`) inside value structs let BPF programs store pointers to kernel objects in maps, with the verifier tracking ownership.

## Key Data Structures

**`struct bpf_map`** (`include/linux/bpf.h`) — the map object:
- `ops` — `struct bpf_map_ops *`; vtable for all operations
- `map_type` — `enum bpf_map_type`
- `key_size` / `value_size` / `max_entries`
- `map_flags` — `BPF_F_NO_PREALLOC`, `BPF_F_LOCK`, `BPF_F_MMAPABLE`, etc.
- `btf` — associated BTF object; `btf_key_type_id` / `btf_value_type_id`
- `refcnt` — `atomic_t`; map freed when zero
- `spin_lock_off` — byte offset of `struct bpf_spin_lock` within the value (if `BPF_F_LOCK`)

**`struct bpf_map_ops`** (`include/linux/bpf.h`) — vtable:
- `map_alloc()` / `map_free()` — allocate/free the backing store
- `map_lookup_elem()` — returns `void *` to the value or NULL
- `map_update_elem()` — insert or update; returns 0 or -errno
- `map_delete_elem()` — remove entry
- `map_push_elem()` / `map_pop_elem()` / `map_peek_elem()` — stack/queue semantics
- `map_get_next_key()` — iteration cursor

## Key Functions / Entry Points

**`map_create()`** (`kernel/bpf/syscall.c`) — validates attrs, calls `ops->map_alloc()`, wraps in anonymous inode, returns fd.

**`bpf_map_lookup_elem()`** (`kernel/bpf/helpers.c`) — BPF helper; dispatches to `map->ops->map_lookup_elem()`.

**`htab_map_lookup_elem()`** (`kernel/bpf/hashtab.c`) — hash map lookup: `jhash(key)` → bucket → RCU list walk.

**`array_map_lookup_elem()`** (`kernel/bpf/arraymap.c`) — array map lookup: `key < max_entries ? &array[key * value_size] : NULL`.

**`bpf_ringbuf_reserve()`** / **`bpf_ringbuf_commit()`** (`kernel/bpf/ringbuf.c`) — ring buffer producer API.

## Important Flags & Config Options

- `BPF_F_NO_PREALLOC` — hash maps allocate per-entry on insert rather than pre-allocating `max_entries` slots; saves memory at the cost of allocation latency and potential ENOMEM.
- `BPF_F_LOCK` — enables `bpf_spin_lock` at offset 0 of the value; required for safe multi-field atomic updates.
- `BPF_F_RDONLY_PROG` / `BPF_F_WRONLY_PROG` — restricts BPF access to the map to read-only or write-only.
- `BPF_MAP_UPDATE_ELEM` flags: `BPF_ANY` (create or update), `BPF_NOEXIST` (create only), `BPF_EXIST` (update only).
- `BPF_F_MMAPABLE` — only valid for array maps; maps the value array directly into userspace via mmap (used by ring buffer).

## Interactions with Other Subsystems

- **↑ Userspace**: `BPF_MAP_CREATE/LOOKUP/UPDATE/DELETE/GET_NEXT_KEY` syscall commands; bpffs pin; `mmap()` for ring buffer and mmapable arrays.
- **→ [[bpf-verifier]]**: The verifier tracks every pointer obtained from `map_lookup_elem()` as `PTR_TO_MAP_VALUE` with known bounds; all dereferences are range-checked.
- **→ [[btf-and-co-re]]**: BTF annotations on map key/value types enable pretty-printing and kptr ownership tracking.
- **→ [[net]]**: `SOCKMAP`/`SOCKHASH` hold `struct sock *` pointers; `bpf_sk_redirect_map()` steers packets at the socket layer.

## Design Decisions & Tradeoffs

**Per-CPU maps vs. single maps with locks** — Per-CPU maps offer strictly better single-threaded performance (no atomic ops) but use `NR_CPUS × value_size` memory and require userspace to aggregate all CPU slices. Single maps with `BPF_F_LOCK` are simpler but serialize updates. Most production monitoring tools use per-CPU arrays for high-frequency counters.

**Ring buffer over perf buffer** — Perf buffers required one fd per CPU, forcing userspace to epoll all fds. The ring buffer uses a single fd and shared memory, simplifying userspace code and reducing memory overhead. The trade-off is a more complex atomic reservation protocol on the BPF side.

**No blocking allocation in BPF helpers** — `bpf_map_update_elem()` for a non-prealloc hash map may fail with ENOMEM in interrupt context. BPF programs must handle NULL returns from lookup and -ENOMEM from update — the kernel cannot block waiting for memory.

## How It Has Evolved

- **3.18 (2014)**: Initial map types: `HASH`, `ARRAY`, `PROG_ARRAY`.
- **4.6 (2016)**: `PERCPU_HASH`, `PERCPU_ARRAY`, `STACK_TRACE`.
- **4.8 (2016)**: `LRU_HASH`, `LRU_PERCPU_HASH` for connection tracking.
- **4.11 (2017)**: `ARRAY_OF_MAPS`, `HASH_OF_MAPS`, `DEVMAP`, `SOCKMAP`.
- **4.15 (2018)**: `SOCKHASH`, `CGROUP_STORAGE`, `REUSEPORT_SOCKARRAY`.
- **5.1 (2019)**: `BPF_MAP_TYPE_QUEUE`, `BPF_MAP_TYPE_STACK` (push/pop semantics).
- **5.8 (2020)**: `BPF_MAP_TYPE_RINGBUF` — single shared ring buffer, mmap-backed.
- **5.20 (2022)**: `BPF_MAP_TYPE_USER_RINGBUF` — userspace-producer direction.
- **6.x**: kptr (`__kptr`, `__kptr_ref`) annotations allow storing kernel pointers in map values with verifier-enforced ownership.

## Further Reading

1. [A thorough introduction to eBPF — LWN.net (2017)](https://lwn.net/Articles/740157/)
2. [BPF ring buffer — LWN.net (2020)](https://lwn.net/Articles/821456/)
3. [BPF Type Format (BTF) — kernel.org docs](https://www.kernel.org/doc/html/latest/bpf/btf.html)
