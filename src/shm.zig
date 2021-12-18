// This file is part of agertu
//
// Copyright (C) 2021 Hugo Machet
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const os = std.os;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const pixman = @import("pixman");

const Output = @import("Output.zig");

const gpa = std.heap.c_allocator;
const log = std.log.scoped(.shm);

pub const Buffer = struct {
    wl_buffer: ?*wl.Buffer,
    data: []align(mem.page_size) u8,
    pixman_image: ?*pixman.Image,

    width: u32 = 0,
    height: u32 = 0,

    busy: bool = false,

    pub fn init(buffer: *Buffer, shm: *wl.Shm, width: u32, height: u32) !void {
        // Open a memory backed "file".
        const fd = try os.memfd_create("agertu-shm-buffer-pool", 0);
        defer os.close(fd);

        const stride = width * 4;
        const size = stride * height;

        try os.ftruncate(fd, size);

        // mmap the memory file, to be used by the pximan image.
        const data = try os.mmap(
            null,
            size,
            os.PROT_READ | os.PROT_WRITE,
            os.MAP_SHARED,
            fd,
            0,
        );
        errdefer os.munmap(data);

        // Create a Wayland shm buffer for the same memory file.
        const pool = try shm.createPool(fd, @intCast(i32, size));
        defer pool.destroy();

        const wl_buffer = try pool.createBuffer(
            0,
            @intCast(i32, width),
            @intCast(i32, height),
            @intCast(i32, stride),
            wl.Shm.Format.argb8888,
        );
        errdefer wl_buffer.destroy();
        wl_buffer.setListener(*Buffer, bufferListener, buffer);

        // Create the pixman image.
        const pixman_image = pixman.Image.createBitsNoClear(
            .a8r8g8b8,
            @intCast(c_int, width),
            @intCast(c_int, height),
            @ptrCast([*c]u32, data),
            @intCast(c_int, stride),
        );
        errdefer _ = pixman_image.unref();

        // The pixman image and the Wayland buffer now share the same memory.
        buffer.* = .{
            .wl_buffer = wl_buffer,
            .data = data,
            .pixman_image = pixman_image,
            .width = width,
            .height = height,
        };

        log.debug("Buffer initialized", .{});
    }

    pub fn destroy(buffer: *Buffer) void {
        if (buffer.pixman_image) |image| _ = image.unref();
        if (buffer.wl_buffer) |wl_buffer| wl_buffer.destroy();
        os.munmap(buffer.data);
    }

    fn bufferListener(wl_buffer: *wl.Buffer, event: wl.Buffer.Event, buffer: *Buffer) void {
        switch (event) {
            // Buffer is no longer used by the compositor. The client is free to reuse
            // or destroy this buffer and its backing storage.
            .release => {
                assert(buffer.busy);
                buffer.busy = false;
            },
        }
    }
};

/// A specialized doubly-linked stack that allows for filtered iteration
/// over the nodes. T must be Buffer or *Buffer.
pub fn BufferStack(comptime T: type) type {
    if (!(T == Buffer or T == *Buffer)) {
        @compileError("BufferStack: T must be Buffer or *Buffer");
    }

    return struct {
        const Self = @This();

        pub const Node = struct {
            prev: ?*Node,
            next: ?*Node,

            buffer: T,
        };

        first: ?*Node = null,
        last: ?*Node = null,

        /// Add a node to the bottom of the stack.
        pub fn append(self: *Self, new_node: *Node) void {
            // Set the prev/next pointers of the new node
            new_node.prev = self.last;
            new_node.next = null;

            if (self.last) |last| {
                // If the list is not empty, set the next pointer of the current
                // first node to the new node.
                last.next = new_node;
            } else {
                // If the list is empty set the first pointer to the new node.
                self.first = new_node;
            }

            // Set the last pointer to the new node
            self.last = new_node;
        }

        /// Remove a node from the buffer stack.
        pub fn remove(self: *Self, target_node: *Node) void {
            // Set the previous node/list head to the next pointer
            if (target_node.prev) |prev_node| {
                prev_node.next = target_node.next;
            } else {
                self.first = target_node.next;
            }

            // Set the next node/list tail to the previous pointer
            if (target_node.next) |next_node| {
                next_node.prev = target_node.prev;
            } else {
                self.last = target_node.prev;
            }
        }

        /// Remove and return the last node in the list.
        pub fn pop(self: *Self) ?*Node {
            const last = self.last orelse return null;
            self.remove(last);
            return last;
        }

        /// Remove and return the first node in the list.
        pub fn popFirst(self: *Self) ?*Node {
            const first = self.first orelse return null;
            self.remove(first);
            return first;
        }

        const Direction = enum {
            forward,
            reverse,
        };

        fn Iter(comptime Context: type) type {
            return struct {
                it: ?*Node,
                dir: Direction,
                context: Context,
                filter: fn (*Buffer, Context) bool,

                /// Returns the next node in iteration or null if done.
                pub fn next(self: *@This()) ?*Buffer {
                    return while (self.it) |node| : (self.it = if (self.dir == .forward) node.next else node.prev) {
                        const buffer = if (T == Buffer) &node.buffer else node.buffer;
                        if (self.filter(buffer, self.context)) {
                            self.it = if (self.dir == .forward) node.next else node.prev;
                            break buffer;
                        }
                    } else null;
                }
            };
        }

        /// Return a filtered iterator over the stack given a start node,
        /// iteration direction, and filter function. Buffers for which the
        /// filter function returns false will be skipped.
        pub fn iter(
            start: ?*Node,
            dir: Direction,
            context: anytype,
            filter: fn (*Buffer, @TypeOf(context)) bool,
        ) Iter(@TypeOf(context)) {
            return .{ .it = start, .dir = dir, .context = context, .filter = filter };
        }
    };
}

test "append/remove/pop (*Buffer)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var buffers = BufferStack(*Buffer){};

    const one = try allocator.create(BufferStack(*Buffer).Node);
    defer allocator.destroy(one);
    const two = try allocator.create(BufferStack(*Buffer).Node);
    defer allocator.destroy(two);
    const three = try allocator.create(BufferStack(*Buffer).Node);
    defer allocator.destroy(three);
    const four = try allocator.create(BufferStack(*Buffer).Node);
    defer allocator.destroy(four);
    const five = try allocator.create(BufferStack(*Buffer).Node);
    defer allocator.destroy(five);

    buffers.append(three); // {3}
    buffers.append(one); // {3, 1}
    buffers.append(four); // {3, 1, 4}
    buffers.append(five); // {3, 1, 4, 5}
    buffers.append(two); // {3, 1, 4, 5, 2}

    // Simple insertion
    {
        var it = buffers.first;
        try testing.expect(it == three);
        it = it.?.next;
        try testing.expect(it == one);
        it = it.?.next;
        try testing.expect(it == four);
        it = it.?.next;
        try testing.expect(it == five);
        it = it.?.next;
        try testing.expect(it == two);
        it = it.?.next;

        try testing.expect(it == null);

        try testing.expect(buffers.first == three);
        try testing.expect(buffers.last == two);
    }

    // Removal of first
    buffers.remove(three);
    {
        var it = buffers.first;
        try testing.expect(it == one);
        it = it.?.next;
        try testing.expect(it == four);
        it = it.?.next;
        try testing.expect(it == five);
        it = it.?.next;
        try testing.expect(it == two);
        it = it.?.next;

        try testing.expect(it == null);

        try testing.expect(buffers.first == one);
        try testing.expect(buffers.last == two);
    }

    // Removal of last
    buffers.remove(two);
    {
        var it = buffers.first;
        try testing.expect(it == one);
        it = it.?.next;
        try testing.expect(it == four);
        it = it.?.next;
        try testing.expect(it == five);
        it = it.?.next;

        try testing.expect(it == null);

        try testing.expect(buffers.first == one);
        try testing.expect(buffers.last == five);
    }

    // Remove from middle
    buffers.remove(four);
    {
        var it = buffers.first;
        try testing.expect(it == one);
        it = it.?.next;
        try testing.expect(it == five);
        it = it.?.next;

        try testing.expect(it == null);

        try testing.expect(buffers.first == one);
        try testing.expect(buffers.last == five);
    }

    // Reinsertion
    buffers.append(two);
    buffers.append(three);
    buffers.append(four);
    {
        var it = buffers.first;
        try testing.expect(it == one);
        it = it.?.next;
        try testing.expect(it == five);
        it = it.?.next;
        try testing.expect(it == two);
        it = it.?.next;
        try testing.expect(it == three);
        it = it.?.next;
        try testing.expect(it == four);
        it = it.?.next;

        try testing.expect(it == null);

        try testing.expect(buffers.first == one);
        try testing.expect(buffers.last == four);
    }

    // Pop
    {
        var buf = buffers.pop();
        try testing.expect(buf == four);
        try testing.expect(buffers.last == three);

        buf = buffers.popFirst();
        try testing.expect(buf == one);
        try testing.expect(buffers.first == five);
    }

    // Clear
    buffers.remove(four);
    buffers.remove(two);
    buffers.remove(three);
    buffers.remove(one);
    buffers.remove(five);

    try testing.expect(buffers.first == null);
    try testing.expect(buffers.last == null);
}

test "iteration (Buffer)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const filters = struct {
        fn all(buffer: *Buffer, context: void) bool {
            return true;
        }

        fn none(buffer: *Buffer, context: void) bool {
            return false;
        }

        fn notBusy(buffer: *Buffer, context: void) bool {
            return !buffer.busy;
        }

        fn busy(buffer: *Buffer, context: void) bool {
            return buffer.busy;
        }
    };

    var buffers = BufferStack(Buffer){};

    const one = try allocator.create(BufferStack(Buffer).Node);
    defer allocator.destroy(one);
    one.buffer.busy = false;

    const two = try allocator.create(BufferStack(Buffer).Node);
    defer allocator.destroy(two);
    two.buffer.busy = true;

    const three = try allocator.create(BufferStack(Buffer).Node);
    defer allocator.destroy(three);
    three.buffer.busy = true;

    const four = try allocator.create(BufferStack(Buffer).Node);
    defer allocator.destroy(four);
    four.buffer.busy = false;

    const five = try allocator.create(BufferStack(Buffer).Node);
    defer allocator.destroy(five);
    five.buffer.busy = true;

    buffers.append(three); // {3}
    buffers.append(one); // {3, 1}
    buffers.append(four); // {3, 1, 4}
    buffers.append(five); // {3, 1, 4, 5}
    buffers.append(two); // {3, 1, 4, 5, 2}

    // Iteration over all buffers
    {
        var it = BufferStack(Buffer).iter(buffers.first, .forward, {}, filters.all);
        try testing.expect(it.next() == &three.buffer);
        try testing.expect(it.next() == &one.buffer);
        try testing.expect(it.next() == &four.buffer);
        try testing.expect(it.next() == &five.buffer);
        try testing.expect(it.next() == &two.buffer);
        try testing.expect(it.next() == null);
    }

    // Iteration over no buffers
    {
        var it = BufferStack(Buffer).iter(buffers.first, .forward, {}, filters.none);
        try testing.expect(it.next() == null);
    }

    // Iteration over buffers not busy
    {
        var it = BufferStack(Buffer).iter(buffers.first, .forward, {}, filters.notBusy);
        try testing.expect(it.next() == &one.buffer);
        try testing.expect(it.next() == &four.buffer);
        try testing.expect(it.next() == null);
    }

    // Reverse iteration over buffers busy
    {
        var it = BufferStack(Buffer).iter(buffers.last, .reverse, {}, filters.busy);
        try testing.expect(it.next() == &two.buffer);
        try testing.expect(it.next() == &five.buffer);
        try testing.expect(it.next() == &three.buffer);
        try testing.expect(it.next() == null);
    }
}
