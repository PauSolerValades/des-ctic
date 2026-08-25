const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// RegionAllocator: a size-classed free-list allocator over ONE large mmap
/// reservation (MAP_NORESERVE). Every allocation shares a single virtual
/// memory area, so the process's `vm.max_map_count` is not a function of the
/// allocation count; and freed blocks are returned to per-size-class buckets,
/// so `realloc` growth (alloc + copy + free) reclaims memory in O(1).
///
/// This is the allocator the per-user timelines use: many ~equal-sized
/// growable buffers, each of which would otherwise become its own mmap/VMA.
///
/// Size classes are power-of-two, 16 KiB .. 256 MiB. Requests larger than the
/// largest class are bumped exactly and leaked on free (hub users only; rare).
///
/// Thread-safe via a spinlock (critical sections are a couple of instructions).
/// ponytail: single global lock; move to per-thread buckets if it shows up in a
/// profile under many workers.
pub const RegionAllocator = struct {
    region: []u8,
    offset: usize = 0,
    free_list: [num_classes]?*Node = @splat(null), // this is an array of linked lists
    mutex: std.atomic.Mutex = .unlocked,

    const min_class_bits = 14; // 16 KiB
    const num_classes = 15; // 16 KiB .. 256 MiB (2^14 .. 2^28)

    const Node = struct {
        next: ?*Node,
    };

    const vtable = Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    /// Reserve `size` bytes of virtual address space as one mapping.
    pub fn init(size: usize) !RegionAllocator {
        const region = try std.posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true },
            -1,
            0,
        );
        return .{ .region = region };
    }

    pub fn deinit(self: *RegionAllocator) void {
        std.posix.munmap(@alignCast(self.region));
    }

    pub fn allocator(self: *RegionAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn classOf(len: usize) usize {
        const bits = std.math.log2_int_ceil(usize, @max(len, 1));
        if (bits < min_class_bits) return 0;
        return @min(bits - min_class_bits, num_classes - 1);
    }

    fn classSize(class: usize) usize {
        return @as(usize, 1) << @intCast(min_class_bits + class);
    }

    fn lock(self: *RegionAllocator) void {
        while (!self.mutex.tryLock()) {}
    }

    fn unlock(self: *RegionAllocator) void {
        self.mutex.unlock();
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *RegionAllocator = @ptrCast(@alignCast(ctx));
        if (len == 0) return null;
        const al = @max(alignment.toByteUnits(), @alignOf(Node));
        self.lock();
        defer self.unlock();

        // Oversized: bump exactly, never reclaimed (rare hub timelines).
        if (len > classSize(num_classes - 1)) {
            const start = std.mem.alignForward(usize, self.offset, al);
            const end = start + len;
            if (end > self.region.len) return null;
            self.offset = end;
            return self.region.ptr + start;
        }

        const class = classOf(len);
        if (self.free_list[class]) |node| {
            self.free_list[class] = node.next;
            return @ptrCast(node);
        }
        const start = std.mem.alignForward(usize, self.offset, al);
        const end = start + classSize(class);
        if (end > self.region.len) {
            std.debug.print("REGION-OOM need={d} offset={d} region={d}\n", .{ len, self.offset, self.region.len });
            return null;
        }
        self.offset = end;
        return self.region.ptr + start;
    }

    fn free(ctx: *anyopaque, mem: []u8, alignment: Alignment, ret_addr: usize) void {
        _ = alignment;
        _ = ret_addr;
        const self: *RegionAllocator = @ptrCast(@alignCast(ctx));
        if (mem.len == 0) return;
        if (mem.len > classSize(num_classes - 1)) return; // oversized: leaked
        const class = classOf(mem.len);
        const node: *Node = @ptrCast(@alignCast(mem.ptr));
        self.lock();
        defer self.unlock();
        node.next = self.free_list[class];
        self.free_list[class] = node;
    }

    fn resize(ctx: *anyopaque, mem: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        _ = .{ ctx, mem, alignment, new_len, ret_addr };
        return false; // never in place; realloc falls back to alloc+copy+free
    }

    fn remap(ctx: *anyopaque, mem: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = .{ ctx, mem, alignment, new_len, ret_addr };
        return null;
    }
};
