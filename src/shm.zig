// This file is part of agertu, popup with information for river
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
const log = std.log.scoped(.agertu_buffer);

pub const Buffer = struct {
    const Self = @This();

    wl_buffer: ?*wl.Buffer,
    data: []align(mem.page_size) u8,
    pixman_image: ?*pixman.Image,

    width: u32 = 0,
    height: u32 = 0,

    busy: bool = false,

    pub fn create(shm: *wl.Shm, width: u32, height: u32) !Self {
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
        var buffer = Self{
            .wl_buffer = wl_buffer,
            .data = data,
            .pixman_image = pixman_image,
            .width = width,
            .height = height,
        };
        wl_buffer.setListener(*Self, bufferListener, &buffer);

        log.debug("Buffer initialized", .{});

        return buffer;
    }

    pub fn destroy(self: *Self) void {
        if (self.pixman_image) |image| _ = image.unref();
        if (self.wl_buffer) |wl_buffer| wl_buffer.destroy();
        os.munmap(self.data);
    }

    fn bufferListener(wl_buffer: *wl.Buffer, event: wl.Buffer.Event, self: *Self) void {
        switch (event) {
            // Buffer is no longer used by the compositor. The client is free to reuse
            // or destroy this buffer and its backing storage.
            .release => {
                assert(self.busy);
                self.busy = false;
            },
        }
    }
};
