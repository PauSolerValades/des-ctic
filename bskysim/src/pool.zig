const std = @import("std");
const Allocator = std.mem.Allocator;

/// Pre-allocated slab of fixed-size slots for DaryHeap backing buffers.
/// One big contiguous allocation, partitioned into num_users*2 slots
/// (a and b timeline per user). Exposes an Allocator interface so
/// DaryHeap can use it transparently.
///
/// Slot overflow falls back to the backing GPA — recorded as a counter
/// so we can measure whether the slot size was sufficient.
pub const TimelinePool = struct {
    /// Contiguous buffer holding all slots
    buffer: []u8,
    /// Size of each slot in bytes
    slot_bytes: usize,
    /// Number of timeline slots total (num_users * 2)
    total_slots: usize,
    /// Free-list stack of available slot indices
    free_stack: []usize,
    /// Free stack pointer (next push position)
    free_sp: usize,
    /// How many times realloc/remap fell back to backing GPA
    gpa_fallbacks: usize,
    /// Backing allocator for initial buffer and overflow
    backing: Allocator,

    pub fn init(backing: Allocator, num_users: usize, slot_capacity: usize) !TimelinePool {
        const total_slots = num_users * 2; // a + b per user
        const slot_bytes = slot_capacity * @sizeOf(TimelineEvent);
        const total_bytes = total_slots * slot_bytes;

        const buffer = try backing.alloc(u8, total_bytes);
        errdefer backing.free(buffer);

        const free_stack = try backing.alloc(usize, total_slots);
        errdefer backing.free(free_stack);

        for (0..total_slots) |i| {
            free_stack[i] = i;
        }

        return .{
            .buffer = buffer,
            .slot_bytes = slot_bytes,
            .total_slots = total_slots,
            .free_stack = free_stack,
            .free_sp = total_slots,
            .gpa_fallbacks = 0,
            .backing = backing,
        };
    }

    pub fn deinit(self: *TimelinePool) void {
        self.backing.free(self.buffer);
        self.backing.free(self.free_stack);
        self.* = undefined;
    }

    /// Return all slots to free list. Buffer stays allocated.
    pub fn reset(self: *TimelinePool) void {
        for (0..self.total_slots) |i| {
            self.free_stack[i] = i;
        }
        self.free_sp = self.total_slots;
        self.gpa_fallbacks = 0;
    }

    /// Returns an Allocator that serves from this pool.
    pub fn allocator(self: *TimelinePool) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = allocFn,
                .resize = resizeFn,
                .remap = remapFn,
                .free = freeFn,
            },
        };
    }

    fn inPool(self: *TimelinePool, ptr: [*]const u8) bool {
        const buf_start = @intFromPtr(self.buffer.ptr);
        const buf_end = buf_start + self.buffer.len;
        const p = @intFromPtr(ptr);
        return p >= buf_start and p < buf_end;
    }

    /// Allocate a slot from the pool. Returns a slice of the slot bytes.
    fn takeSlot(self: *TimelinePool) ?[*]u8 {
        if (self.free_sp == 0) return null;
        self.free_sp -= 1;
        const idx = self.free_stack[self.free_sp];
        return self.buffer.ptr + idx * self.slot_bytes;
    }

    fn returnSlot(self: *TimelinePool, ptr: [*]const u8) void {
        const offset = @intFromPtr(ptr) - @intFromPtr(self.buffer.ptr);
        const idx = offset / self.slot_bytes;
        self.free_stack[self.free_sp] = idx;
        self.free_sp += 1;
    }

    // -- Allocator vtable --

    fn allocFn(ctx: *anyopaque, len: usize, log2_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TimelinePool = @ptrCast(@alignCast(ctx));

        // Only serve requests that fit in a single slot
        // Slot alignment = pointer alignment (3 = 8 bytes on 64-bit)
        if (len <= self.slot_bytes and @intFromEnum(log2_align) <= 3) {
            return self.takeSlot();
        }
        return self.backing.rawAlloc(len, log2_align, ret_addr);
    }

    fn resizeFn(ctx: *anyopaque, buf: []u8, log2_buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TimelinePool = @ptrCast(@alignCast(ctx));

        if (self.inPool(buf.ptr)) {
            if (new_len <= self.slot_bytes) return true;
            self.gpa_fallbacks += 1;
            return false; // can't grow in place
        }
        return self.backing.rawResize(buf, log2_buf_align, new_len, ret_addr);
    }

    fn remapFn(ctx: *anyopaque, buf: []u8, log2_buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TimelinePool = @ptrCast(@alignCast(ctx));

        if (self.inPool(buf.ptr)) {
            if (new_len <= self.slot_bytes) return buf.ptr;
            // Overflow: alloc from backing, copy old data, return slot to pool.
            self.gpa_fallbacks += 1;
            const new_ptr = self.backing.rawAlloc(new_len, log2_buf_align, ret_addr) orelse return null;
            @memcpy(new_ptr[0..buf.len], buf);
            self.returnSlot(buf.ptr);
            return new_ptr;
        }
        return self.backing.rawRemap(buf, log2_buf_align, new_len, ret_addr);
    }

    fn freeFn(ctx: *anyopaque, buf: []u8, log2_buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *TimelinePool = @ptrCast(@alignCast(ctx));

        if (self.inPool(buf.ptr)) {
            self.returnSlot(buf.ptr);
        } else {
            self.backing.rawFree(buf, log2_buf_align, ret_addr);
        }
    }
};

const TimelineEvent = struct { time: f64, post_id: u32, parent_id: u32 };

test "alloc and free slots" {
    const b = std.testing.allocator;
    var pool = try TimelinePool.init(b, 3, 64);
    defer pool.deinit();

    const a = pool.allocator();
    const m1 = try a.alloc(u8, pool.slot_bytes);
    const m2 = try a.alloc(u8, pool.slot_bytes);
    try std.testing.expect(m1.ptr != m2.ptr);

    a.free(m1);
    const m3 = try a.alloc(u8, pool.slot_bytes);
    try std.testing.expectEqual(m1.ptr, m3.ptr); // reused
}

test "reset" {
    const b = std.testing.allocator;
    var pool = try TimelinePool.init(b, 2, 32);
    defer pool.deinit();

    const a = pool.allocator();
    _ = try a.alloc(u8, pool.slot_bytes);
    _ = try a.alloc(u8, pool.slot_bytes);
    pool.reset();
    _ = try a.alloc(u8, pool.slot_bytes);
    _ = try a.alloc(u8, pool.slot_bytes);
    // no error = pass
}

test "overflow falls back to backing" {
    const b = std.testing.allocator;
    var pool = try TimelinePool.init(b, 1, 64);
    defer pool.deinit();

    const a = pool.allocator();
    var m = try a.alloc(u8, pool.slot_bytes);
    // Grow beyond slot size — should fall back
    m = try a.realloc(m, pool.slot_bytes * 2);
    defer a.free(m);
    try std.testing.expectEqual(@as(usize, 1), pool.gpa_fallbacks);
    try std.testing.expect(m.len >= pool.slot_bytes * 2);
}
