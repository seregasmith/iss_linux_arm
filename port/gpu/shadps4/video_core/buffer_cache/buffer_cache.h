// SPDX-FileCopyrightText: Copyright 2024 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include "tlg_copy.h"

#include <array>
#include <atomic>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <tuple>
#include <vector>
#include <optional>
#include <utility>
#include <boost/container/small_vector.hpp>

#include "common/interval_set.h"
#include "common/types.h"
#include "video_core/buffer_cache/buffer.h"
#include "video_core/buffer_cache/fault_manager.h"
#include "video_core/buffer_cache/range_set.h"
#include "video_core/renderer_vulkan/vk_semaphore.h"
#include "video_core/renderer_vulkan/vk_staging_buffer_pool.h"

namespace AmdGpu {
struct Liverpool;
}

namespace Core {
class MemoryManager;
}

namespace Vulkan {
class GraphicsPipeline;
struct SubmitInfo;
class Runtime;
class StagingBufferPool;
} // namespace Vulkan

namespace VideoCore {

class TextureCache;
class MemoryTracker;
class PageManager;

class BufferCache {
    static constexpr u64 ADDRESS_SPACE_BITS = 40;
    // tlg: arena pages are 4 GiB unless the driver's buffer size limit is lower (AMD's
    // Windows driver: 2 GiB); an arena spans up to two pages, so they shrink to half the limit.
    static constexpr u64 MAX_ARENA_PAGE_BITS = 32;
    static constexpr u64 MIN_ARENA_PAGE_BITS = 29;
    static constexpr u64 MAX_ARENA_PAGES = u64{1} << (ADDRESS_SPACE_BITS - MIN_ARENA_PAGE_BITS);
    static constexpr u64 MIN_BLOCK_SIZE = 16_KB;

public:
    /// Read-only bindings up to this size are copied into a stream buffer (tlg: public for
    /// the draw pipeline's constant ring).
    static constexpr u64 STREAM_THRESHOLD = 16_KB;
    /// tlg (shadPS4-Infamous-FixBuild a107bf06): uploads larger than this go through staging
    /// memory of this size, a part at a time. Loading a save in inFAMOUS Second Son one draw reads
    /// 2.4 GB the game wrote at once, and staging memory that large could not be allocated.
    static constexpr u64 MAX_UPLOAD_PART_BYTES = 256_MB;

    explicit BufferCache(const Vulkan::Instance& instance, Vulkan::Scheduler& scheduler,
                         Vulkan::Runtime& runtime, AmdGpu::Liverpool* liverpool,
                         TextureCache& texture_cache, PageManager& tracker);
    ~BufferCache();

    /// Returns a pointer to GDS device local buffer.
    [[nodiscard]] const Buffer* GetGdsBuffer() const noexcept {
        return &gds_buffer;
    }

    /// Retrieves the device local DBA page table buffer.
    [[nodiscard]] Buffer* GetBdaPageTableBuffer() noexcept {
        return bda_pagetable_buffer.get();
    }

    /// Retrieves the fault buffer.
    [[nodiscard]] Buffer* GetFaultBuffer() noexcept {
        return fault_manager->GetFaultBuffer();
    }

    /// Retrieves the stream buffer.
    StreamBuffer& GetStreamBuffer() noexcept {
        return stream_buffer;
    }

    /// Returns minimum granularity of a sparse memory bind.
    u32 GetSparsePageShift() const noexcept {
        return block_shift;
    }

    /// Invalidates any buffer in the logical page range.
    void InvalidateMemory(VAddr device_addr, u64 size, bool assume_locks = false);

    /// tlg: a guest write fault at `device_addr` was handled; unprotect its neighbourhood.
    void ExtendWriteFault(VAddr device_addr);

    /// Flushes any GPU modified buffer in the logical page range back to CPU memory.
    void ReadMemory(VAddr device_addr, u64 size, bool is_write = false, bool assume_locks = false);
    /// tlg: a CPU read fault on pages with no GPU-modified data: lift the read protection on the
    /// faulting thread instead of a round trip through the GPU command thread.
    void ReleaseReadProtection(VAddr device_addr, u64 size);

    /// Finds a buffer for the specified region.
    [[nodiscard]] std::pair<const Buffer*, u64> ObtainBuffer(VAddr device_addr, u32 size,
                                                             bool is_written,
                                                             bool is_texel_buffer = false);

    /// Attempts to obtain a buffer without modifying the cache contents.
    [[nodiscard]] std::pair<const Buffer*, u64> ObtainBufferForImage(VAddr device_addr, u32 size);

    /// Return true when a region is modified from the CPU
    [[nodiscard]] bool IsRegionCpuModified(VAddr addr, size_t size);

    /// Return true when a region is modified from the GPU
    [[nodiscard]] bool IsRegionGpuModified(VAddr addr, size_t size);

    /// Processes the fault buffer.
    void ProcessFaultBuffer();

    /// Synchronizes all buffers needed for DMA.
    void SynchronizeDmaBuffers();

    /// Commits pending sparse buffer memory binds. Must be called before every scheduler submit.
    void SubmitPendingArenaBinds(Vulkan::SubmitInfo& info);

private:
    struct ArenaBinds {
        const Buffer* arena;
        boost::container::small_vector<vk::SparseMemoryBind, 32> binds;
    };

    ArenaBinds* BindsForArena(const Buffer* arena) {
        auto it = std::ranges::find(pending_binds, arena, &ArenaBinds::arena);
        if (it != pending_binds.end()) {
            return std::addressof(*it);
        }
        return &pending_binds.emplace_back(arena);
    }

    const Buffer* GetArena(u64 first_block, u64 last_block);

    void EnsureResident(const Buffer* arena, u64 first_block, u64 last_block);

    /// tlg: residency state when EnsureResident started, and the driver allocations made since.
    struct ResidencyAttempt {
        vk::DeviceMemory chunk;
        u64 chunk_used;
        boost::container::small_vector<vk::DeviceMemory, 4> allocated{};
    };

    /// Returns device memory and an offset into it (bytes) to back size bytes of arena blocks,
    /// or nothing when the device is out of memory (UndoResidency then frees the attempt's).
    std::optional<std::pair<vk::DeviceMemory, u64>> AllocateResidency(u64 size,
                                                                       ResidencyAttempt& attempt);
    void UndoResidency(const ResidencyAttempt& attempt);

    /// Frees old textures and waits for the GPU to release their memory, after an allocation
    /// for residency failed for lack of device memory.
    void ReleaseMemoryForResidency(u64 bytes);

    void DownloadMemory(const Buffer* arena, VAddr device_addr, u64 size);

public:
    /// tlg: TLG_WRITE_MERGE=1 (precise readbacks): a guest memcpy/memset into memory with
    /// GPU-modified pages writes through the backing view without a fault or a GPU wait, and the
    /// exact byte range is uploaded before the GPU next uses or downloads it. Bytes the GPU
    /// wrote elsewhere on those pages stay intact. False: the caller writes normally.
    bool CpuWriteMerge(VAddr dst, const void* src, int fill, u64 size);

    /// tlg: TLG_EAGER_READBACK=1 (precise readbacks): pages the guest reads back after GPU
    /// writes are learnt (NoteReadback). At every fence they are copied to host memory if the
    /// GPU wrote them since, and the batch is submitted (EagerCopyAtFence). A later CPU read
    /// fault on such a page is served on the faulting thread (TryEagerRead): it waits only for
    /// that copy, not for the GPU command thread nor for a full GPU idle.
    bool TryEagerRead(VAddr addr, u64 size);
    void NoteReadback(VAddr addr, u64 size);
    void EagerCopyAtFence();

    /// tlg: TLG_STALE_BUFFER_READS=1 (deferred readbacks, precise mode): a CPU read fault on GPU
    /// modified memory does not wait. The pages around it become readable as they are (the copy
    /// published last, about a frame old) while staying GPU modified, and a copy of the current
    /// GPU data is recorded; when the GPU has made it, it is written back (FinishStaleCopy), even
    /// if the GPU wrote the memory again meanwhile (then the pages stay GPU modified). CPU writes
    /// still wait for the GPU data, so no byte the GPU or the CPU wrote is lost; only reads may
    /// see a frame-old version. False: the caller reads back the precise way. Guest threads.
    bool TryStaleRead(VAddr addr, u64 size);

    /// tlg: TLG_TWIN_WRITES=1 (with stale buffer reads): a CPU write fault on GPU modified memory
    /// does not wait either. The page is kept as it is (its twin) and made writable while it stays
    /// GPU modified. The bytes the CPU changed are found by comparing the page with its twin
    /// (HarvestTwins) and sent to the GPU before it runs the game's next submission or copies the
    /// memory back; GPU data copied back is merged in word by word around them (WriteGpuData).
    /// When the GPU data is back for good the twin goes (SettleTwins). False: the caller takes
    /// the usual path (no GPU data on the page, no room for more twins). Guest threads.
    bool TryTwinWrite(VAddr addr, u64 size);
    static bool TwinWritesEnabled();

private:
    /// Uploads the merged guest writes inside [device_addr, device_addr + size) of `arena`.
    void FlushMergedWrites(const Buffer* arena, VAddr device_addr, u64 size);
    std::mutex merge_mutex;
    std::map<VAddr, VAddr> merged_writes; ///< start -> end, disjoint
    std::atomic<u64> merged_count{0};

    struct EagerPage {
        u64 offset;   ///< in eager_buffer
        u64 tick;     ///< submission holding the last copy
        bool dirty;   ///< GPU wrote it since the last copy
        bool valid;   ///< the copy at `tick` is current
        u32 idle;     ///< fences since the guest last read it
        /// Fences to skip before copying it again, after copies of it went stale unread
        /// (backoff doubles each time, up to EagerMaxBackoff; a read resets it).
        u8 backoff;
        u8 skip;
    };
    static bool EagerEnabled();
    void NoteGpuWriteForEager(VAddr addr, u64 size); ///< GPU-side threads, before the write
    void MarkEagerStale(VAddr addr, u64 size);       ///< any thread: CPU bytes the copy lacks
    void ApplyEagerSubtractsLocked();                ///< GPU-side threads, eager_mutex held
    std::mutex eager_mutex;
    std::map<VAddr, EagerPage> eager_pages; ///< by 4 KiB page address
    std::vector<VAddr> eager_free_offsets;
    u64 eager_next_offset = 0;
    std::atomic<u32> eager_count{0};
    std::vector<VAddr> eager_subtracts; ///< pages served on guest threads: leave gpu_modified_ranges
    std::unique_ptr<Buffer> eager_buffer;

    /// tlg: TLG_DEFERRED_READBACK=1 (precise readbacks): the reads the eager copies don't cover.
    /// The GPU command thread only records a copy of the GPU modified memory around the fault
    /// and submits it; the guest thread that faulted waits for that copy (not for the whole GPU
    /// to go idle) and writes it back and unmarks it itself. Guest threads touching the same
    /// memory meanwhile wait for the same copy. A GPU write to the memory before the copy is
    /// applied marks it stale (before the memory is marked GPU modified again, see
    /// MemoryTracker::ApplyGpuCopyIf), and so does a CPU write without a fault (CpuWriteMerge):
    /// then the guest falls back to the old download. From shadPS4-Infamous-FixBuild ee423726
    /// and 2d2511fe. With TLG_READBACK_LOCAL_JOIN=1 a faulting guest thread that finds a copy
    /// covering its window applies it itself (see PendingDeferredReadback).
    struct DeferredReadback {
        Vulkan::StagingBufferRef staging;
        /// Source offsets into the arena, destination offsets into the staging buffer.
        boost::container::small_vector<vk::BufferCopy, 8> copies;
        VAddr arena_base{};
        VAddr start{};
        VAddr end{};
        u64 tick{};
        std::atomic<bool> stale{};
        std::atomic<bool> applied{};
        /// tlg (stale buffer reads): the CPU wrote the memory after the copy was recorded, so
        /// the copy must not be published over it; and a publish is scheduled (keeps the staging).
        std::atomic<bool> cpu_written{};
        std::atomic<bool> publish_pending{};
        /// tlg (twin writes): its place among the harvests (twin_sequence), taken when recorded.
        u64 sequence{};
        /// Won't be applied; its ranges are back in gpu_modified_ranges.
        std::atomic<bool> recovered{};
        std::mutex mutex;
        bool Done() const noexcept {
            return applied.load(std::memory_order_acquire) ||
                   recovered.load(std::memory_order_acquire);
        }
    };
    static bool DeferredReadbackEnabled();
    /// tlg: TLG_READBACK_LOCAL_JOIN=1: a faulting guest thread applies a pending copy that
    /// covers its window itself instead of asking the GPU command thread for one.
    static bool LocalReadbackJoin();
    /// tlg: waits for a readback copy tick with the readback wait counters (TLG_READBACK_STATS)
    /// and the scheduler's submit-if-needed fallback; the scheduler's tick_wait_ns misses these.
    void WaitReadbackTick(u64 tick);
    /// The arena and the window around a range that is read back with it.
    std::tuple<const Buffer*, VAddr, VAddr> GetReadbackWindow(VAddr device_addr, u64 size);
    /// Takes the GPU modified ranges of a range out of gpu_modified_ranges, adding copies of
    /// them (staging offsets from 0). GPU-side threads.
    u64 CollectDownloads(const Buffer* arena, VAddr device_addr, u64 size,
                         boost::container::small_vector<vk::BufferCopy, 8>& copies);
    /// Records and submits a copy back, or joins one in flight covering it. GPU-side threads.
    std::shared_ptr<DeferredReadback> StartDeferredReadback(VAddr device_addr, u64 size);
    /// tlg: a copy in flight that is not stale and covers the readback window of the range, or
    /// nothing. Any thread; the caller applies it with FinishDeferredReadback.
    std::shared_ptr<DeferredReadback> PendingDeferredReadback(VAddr device_addr, u64 size);
    /// Waits for the copy (if `wait`) and applies it. False when it is stale. Any thread.
    bool FinishDeferredReadback(DeferredReadback& readback, bool wait);
    /// Puts the ranges of a copy that won't be applied back into gpu_modified_ranges.
    /// GPU-side threads.
    void RecoverDeferredReadback(DeferredReadback& readback);
    /// Applies or recovers the copies in flight overlapping [start, end). GPU-side threads.
    void SettleDeferredReadbacks(VAddr start, VAddr end);
    /// Recovers stale copies and frees the staging memory of finished ones. GPU-side threads.
    void PruneDeferredReadbacks();
    /// Marks the copies in flight overlapping a range stale. `cpu`: a guest thread is about to
    /// write the memory without a fault, so an apply in progress is waited for. Any thread.
    void MarkDeferredStale(VAddr addr, u64 size, bool cpu);
    /// tlg (stale buffer reads): see TryStaleRead.
    static bool StaleReadsEnabled();
    /// Records the copy for a stale read and schedules FinishStaleCopy. GPU-side threads.
    void StartStaleCopy(VAddr addr, u64 size);
    /// Applies the copy (the GPU has made it), or publishes it when the GPU wrote the memory
    /// again since. Any thread.
    void FinishStaleCopy(DeferredReadback& readback);
    /// Writes the bytes of a copy into guest memory for [start, end). Under readback.mutex.
    void WriteDeferredCopy(const DeferredReadback& readback, VAddr start, VAddr end);
    /// The copies in flight overlapping a range the CPU is about to write must not be
    /// published over it. Any thread.
    void MarkDeferredCpuWritten(VAddr addr, u64 size);

    /// tlg (twin writes, see TryTwinWrite).
    struct TwinPage {
        std::array<u64, 512> words{}; ///< the page as the CPU and the GPU last agreed on it
        std::array<u32, 512> seq{};   ///< per word: the harvest that last sent CPU bytes of it
        u8* backing = nullptr;        ///< the page through the backing view
    };
    /// Finds the CPU's changes in the twins of pages in [lo, hi) and queues them as merged
    /// writes. GPU-side threads.
    void HarvestTwins(VAddr lo, VAddr hi);
    /// Writes GPU data copied at `sequence` into guest memory; twin pages get it merged in.
    void WriteGpuData(VAddr dst, const u8* src, u64 size, u64 sequence);
    /// Merges GPU data into one twin page, word by word with atomics: bytes the CPU changed
    /// since the twin agreed with the GPU stay, and words whose CPU bytes were sent after the copy
    /// was recorded are left alone. twin_mutex held.
    static void MergeIntoTwin(TwinPage& twin, u64 offset, const u8* src, u64 size, u64 sequence);
    /// Drops the twins of pages in [lo, hi) that are no longer GPU modified; pages the CPU
    /// changed are marked CPU modified (uploaded whole). Any thread.
    void SettleTwins(VAddr lo, VAddr hi);
    /// Adds [start, end) to merged_writes. merge_mutex held.
    void AddMergedRangeLocked(VAddr start, VAddr end);
    std::mutex twin_mutex;
    std::map<VAddr, std::unique_ptr<TwinPage>> twins; ///< by page address
    std::atomic<u32> twin_count{0};
    std::atomic<u64> twin_sequence{1}; ///< stream order of harvests and copies back
    std::atomic<u64> twin_epoch{0};    ///< guest submissions seen by the last full harvest
    std::mutex deferred_mutex; ///< guards the list (guest threads read it)
    std::vector<std::shared_ptr<DeferredReadback>> deferred_readbacks;
    std::atomic<u32> deferred_count{0};

    bool SynchronizeMemory(const Buffer* arena, VAddr device_addr, u32 size, bool is_written,
                           bool is_texel_buffer);

    /// tlg: batched small copies on the copy threads (TlgCopy::QueueCopy).
    static void RunGuestCopy(const TlgCopy::Item& item);
    void SmallGuestCopy(const TlgCopy::Item& item);

    const Buffer* UploadCopies(const Buffer* arena, std::span<vk::BufferCopy> copies,
                               size_t total_size_bytes);

    /// tlg: uploads the ranges (guest addresses in dstOffset) MAX_UPLOAD_PART_BYTES at a time,
    /// waiting for the GPU to copy each part before the staging memory takes the next.
    void UploadInParts(const Buffer* arena, std::span<const vk::BufferCopy> ranges);

    bool SynchronizeMemoryFromImage(const Buffer* arena, VAddr device_addr, u32 size);

    const Vulkan::Instance& instance;
    Vulkan::Scheduler& scheduler;
    // tlg: texel buffer ranges known not to alias an image, per image registry generation.
    struct ImageMiss {
        VAddr address = 0;
        u32 size = 0;
        u64 generation = ~0ULL;
    };
    std::array<ImageMiss, 256> image_miss_cache{};
    Vulkan::Runtime& runtime;
    Vulkan::StagingBufferPool& staging_pool;
    AmdGpu::Liverpool* liverpool;
    Core::MemoryManager* memory;
    TextureCache& texture_cache;
    std::unique_ptr<MemoryTracker> memory_tracker;

    StreamBuffer stream_buffer;
    Buffer gds_buffer;
    RangeSet gpu_modified_ranges;

    std::unique_ptr<FaultManager> fault_manager;
    std::unique_ptr<Buffer> bda_pagetable_buffer;

    std::array<const Buffer*, MAX_ARENA_PAGES> address_space{};
    u64 arena_page_bits{MAX_ARENA_PAGE_BITS};
    /// tlg: pages one arena may join (the driver's buffer size limit / the page size, >= 2).
    u64 max_arena_pages{2};
    u64 arena_page_size{u64{1} << MAX_ARENA_PAGE_BITS};
    u64 num_arena_pages{u64{1} << (ADDRESS_SPACE_BITS - MAX_ARENA_PAGE_BITS)};
    std::deque<Buffer> arenas;
    std::vector<ArenaBinds> pending_binds;
    Vulkan::Semaphore memory_semaphore;

    struct Backing : public Interval {
        vk::DeviceMemory memory;
        u64 offset;
        constexpr bool CanMergeWith(const Backing& other) const noexcept {
            return memory == other.memory && offset + (end - start) == other.offset;
        }
        constexpr Backing SubRange(u64 a, u64 b) const noexcept {
            return {{a, b}, memory, offset + (a - start)};
        }
    };
    IntervalList<Backing> resident_ranges;
    /// tlg: residency is carved out of chunks (see AllocateResidency, from the
    /// shadPS4-Infamous-FixBuild fork). Driver allocations made for it, for the slow-bind log.
    vk::DeviceMemory residency_chunk{};
    u64 residency_chunk_used{};
    u64 residency_allocations{};

    u32 arena_memory_type_index{};
    u32 block_size{};
    u32 block_shift{};
    u32 blocks_per_arena_page{};
    u32 blocks_per_arena_page_shift{};
};

} // namespace VideoCore
