const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ChunkData = struct {
    kind: enum { array, bitmap, run } = .array,
    data: std.ArrayListAlignedUnmanaged(u16, @alignOf(u64)) = .{},

    pub fn deinit(self: *ChunkData, allocator: Allocator) void {
        self.data.deinit(allocator);
    }

    pub fn count(self: ChunkData) u32 {
        switch (self.kind) {
            .array => {
                return @intCast(self.data.items.len);
            },
            .bitmap => {
                std.debug.assert(self.data.items.len == 4096);
                var result: u32 = 0;
                const ptr: [*]u64 = @ptrCast(self.data.items.ptr);
                for (ptr[0..1024]) |word| {
                    result += @popCount(word);
                }
                return result;
            },
            .run => {
                std.debug.assert(self.data.items.len == 2);
                return self.data.items[1] - self.data.items[0] + 1;
            },
        }
    }

    pub fn isSet(self: ChunkData, key: u16) bool {
        switch (self.kind) {
            .array => {
                const index = std.sort.binarySearch(u16, key, self.data.items, {}, sorted_u16);
                return index != null;
            },
            .bitmap => {
                std.debug.assert(self.data.items.len == 4096);
                const index: u12 = @truncate(key >> 4);
                const mask: u16 = @as(u16, 1) << @as(u4, @truncate(key));
                return self.data.items[index] & mask != 0;
            },
            .run => {
                std.debug.assert(self.data.items.len == 2);
                return self.data.items[0] >= key and self.data.items[1] <= key;
            },
        }
    }

    pub fn set(self: *ChunkData, allocator: Allocator, key: u16) !void {
        switch (self.kind) {
            .array => {
                const index = std.sort.lowerBound(u16, key, self.data.items, {}, std.sort.asc(u16));
                if (index < self.data.items.len and self.data.items[index] == key) {
                    return;
                }
                try self.data.insert(allocator, index, key);
            },
            .bitmap => {
                std.debug.assert(self.data.items.len == 4096);
                const index: u12 = @truncate(key >> 4);
                const mask: u16 = @as(u16, 1) << @as(u4, @truncate(key));
                self.data.items[index] |= mask;
            },
            .run => {
                return error.NotImplemented;
            },
        }
    }
};

pub const Chunk = struct {
    base: u16,
    data: ChunkData = .{},
};

fn sorted_u16(context: void, lhs: u16, rhs: u16) std.math.Order {
    _ = context;
    return std.math.order(lhs, rhs);
}

pub const RoaringBitmap = struct {
    items: std.MultiArrayList(Chunk) = .{},

    pub fn deinit(self: *RoaringBitmap, allocator: Allocator) void {
        for (self.items.items(.data)) |*data| {
            data.deinit(allocator);
        }
        self.items.deinit(allocator);
    }

    pub fn set(self: *RoaringBitmap, allocator: Allocator, key: u32) !void {
        const key_high: u16 = @truncate(key >> 16);
        const key_low: u16 = @truncate(key);
        const index = std.sort.lowerBound(u16, key_high, self.items.items(.base), {}, std.sort.asc(u16));
        if (index == self.items.len or self.items.items(.base)[index] != key_high) {
            try self.items.insert(allocator, index, .{ .base = key_high });
        }
        try self.items.items(.data)[index].set(allocator, key_low);
    }

    pub fn isSet(self: *RoaringBitmap, key: u32) bool {
        const key_high: u16 = @truncate(key >> 16);
        const key_low: u16 = @truncate(key);
        const chunk_no = std.sort.binarySearch(u16, key_high, self.items.items(.base), {}, sorted_u16) orelse return false;
        const chunk = self.items.get(chunk_no);
        return chunk.data.isSet(key_low);
    }

    pub fn count(self: RoaringBitmap) u32 {
        var result: u32 = 0;
        for (self.items.items(.data)) |data| {
            result += data.count();
        }
        return result;
    }
};

test "smoke test" {
    const alloc = std.testing.allocator;

    var bitmap: RoaringBitmap = .{};
    defer bitmap.deinit(alloc);

    try std.testing.expectEqual(false, bitmap.isSet(1));
    try std.testing.expectEqual(0, bitmap.count());

    try bitmap.set(alloc, 1);

    try std.testing.expectEqual(true, bitmap.isSet(1));
    try std.testing.expectEqual(1, bitmap.count());
}
