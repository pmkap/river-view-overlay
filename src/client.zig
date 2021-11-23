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
const os = std.os;
const math = std.math;
const mem = std.mem;
const time = std.time;

const fcft = @import("fcft");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zriver = wayland.client.zriver;
const zwlr = wayland.client.zwlr;

const Config = @import("Config.zig");
const Output = @import("Output.zig");

const gpa = std.heap.c_allocator;
const log = std.log.scoped(.client);

pub const Context = struct {
    const Self = @This();

    display: *wl.Display,
    registry: *wl.Registry,
    callback_sync: ?*wl.Callback = null,

    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,

    layer_shell: ?*zwlr.LayerShellV1 = null,
    river_status_manager: ?*zriver.StatusManagerV1 = null,

    config: Config = .{},

    outputs: std.TailQueue(Output) = .{},

    initialized: bool = false,

    pub fn init(self: *Self) !void {
        if (std.builtin.mode == .Debug) fcft.logInit(.auto, true, .debug);

        const display = wl.Display.connect(null) catch {
            std.debug.warn("Unable to connect to Wayland server.\n", .{});
            std.os.exit(1);
        };

        self.* = .{
            .display = display,
            .registry = try display.getRegistry(),
            .callback_sync = try display.sync(),
        };

        self.registry.setListener(*Self, registryListener, self);
        self.callback_sync.?.setListener(*Self, callbackListener, self);

        _ = try self.display.roundtrip();
    }

    pub fn destroy(self: *Self) void {
        var it = self.outputs.first;
        while (it) |node| : (it = node.next) {
            node.data.deinit();
        }

        if (self.compositor) |compositor| compositor.destroy();
        if (self.shm) |shm| shm.destroy();
        if (self.layer_shell) |layer_shell| layer_shell.destroy();
        if (self.river_status_manager) |manager| manager.destroy();

        self.registry.destroy();
        self.display.disconnect();
    }

    pub fn loop(self: *Self) !void {
        var timeout: i64 = -1;
        var start_time: os.timespec = undefined;
        var when: os.timespec = undefined;
        var fds = [1]os.pollfd{
            .{
                .fd = self.display.getFd(),
                .events = os.POLLIN,
                .revents = undefined,
            },
        };

        while (self.initialized) {
            while ((try self.display.dispatchPending()) > 0) {
                _ = try self.display.flush();
            }

            os.clock_gettime(os.CLOCK_MONOTONIC, &start_time) catch @panic("CLOCK_MONOTONIC not supported");

            var it = self.outputs.first;
            while (it) |node| : (it = node.next) {
                const output = &node.data;
                if (output.surface) |surface| {
                    if (!surface.configured) continue;
                    when = timespecDiff(&start_time, surface.last_frame);
                } else continue;

                log.debug("start: {d}\nwhen: {d}", .{ start_time, when });

                const half_second_ns: i64 = 500_000_000; // 0.5 second in nanosecond

                if (when.tv_sec > 0 or
                    when.tv_nsec >= (half_second_ns - time.ns_per_ms))
                {
                    output.surface.?.destroy();
                    output.surface = null;
                } else {
                    timeout = blk: {
                        // ns to ms
                        var _timeout = @divFloor((half_second_ns - when.tv_nsec), time.ns_per_ms);
                        log.debug("_timeout: {d}", .{_timeout});

                        if (timeout == -1 or timeout > _timeout) break :blk @intCast(i32, _timeout);

                        break :blk timeout;
                    };
                }
                log.debug("timeout: {d}", .{timeout});
            }

            _ = try self.display.flush();

            _ = try os.poll(&fds, @intCast(i32, timeout));

            if ((fds[0].revents & os.POLLIN) != 0) {
                _ = try self.display.dispatch();
            }

            if ((fds[0].revents & os.POLLOUT) != 0) {
                _ = try self.display.flush();
            }
        }
    }

    fn addOutput(self: *Self, registry: *wl.Registry, name: u32) !void {
        const wl_output = try registry.bind(name, wl.Output, 3);
        errdefer wl_output.release();

        const node = try gpa.create(std.TailQueue(Output).Node);
        errdefer gpa.destroy(node);
        try node.data.init(self, wl_output, name);
        self.outputs.append(node);

        if (self.river_status_manager) |manager| {
            try node.data.getOutputStatus();
        }
    }
};

fn timespecDiff(ts1: *const os.timespec, ts2: *const os.timespec) os.timespec {
    return blk: {
        if ((ts1.tv_nsec - ts2.tv_nsec) < 0) { // Invalid read of size 8
            break :blk .{
                .tv_sec = (ts1.tv_sec - ts2.tv_sec) - 1,
                .tv_nsec = (ts1.tv_nsec - ts2.tv_nsec) + time.ns_per_s,
            };
        }
        break :blk .{
            .tv_sec = ts1.tv_sec - ts2.tv_sec, // Invalid read of size 8
            .tv_nsec = ts1.tv_nsec - ts2.tv_nsec, // Invalid read of size 8
        };
    };
}

fn timespecToNs(ts: *const os.timespec) i64 {
    return math.add(
        i64,
        math.mul(i64, ts.tv_sec, time.ns_per_s) catch math.maxInt(i64),
        ts.tv_nsec,
    ) catch math.maxInt(i64);
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, self: *Context) void {
    switch (event) {
        .global => |global| {
            if (std.cstr.cmp(global.interface, wl.Compositor.getInterface().name) == 0) {
                self.compositor = registry.bind(global.name, wl.Compositor, 4) catch return;
            } else if (std.cstr.cmp(global.interface, wl.Shm.getInterface().name) == 0) {
                self.shm = registry.bind(global.name, wl.Shm, 1) catch return;
            } else if (std.cstr.cmp(global.interface, wl.Output.getInterface().name) == 0) {
                self.addOutput(registry, global.name) catch |err| {
                    fatal("Failed to bind output: {}", .{err});
                };
            } else if (std.cstr.cmp(global.interface, zwlr.LayerShellV1.getInterface().name) == 0) {
                self.layer_shell = registry.bind(global.name, zwlr.LayerShellV1, 4) catch return;
            } else if (std.cstr.cmp(global.interface, zriver.StatusManagerV1.getInterface().name) == 0) {
                self.river_status_manager = registry.bind(global.name, zriver.StatusManagerV1, 2) catch return;
            }
        },
        .global_remove => |ev| {
            var it = self.outputs.first;
            while (it) |node| : (it = node.next) {
                if (node.data.name == ev.name) {
                    self.outputs.remove(node);
                    node.data.deinit();
                    break;
                }
            }
        },
    }
}

fn callbackListener(callback: *wl.Callback, event: wl.Callback.Event, self: *Context) void {
    switch (event) {
        .done => {
            callback.destroy();
            self.callback_sync = null;

            if (self.compositor == null) {
                fatal("Wayland compositor does not support wl_compositor\n", .{});
            }
            if (self.shm == null) {
                fatal("Wayland compositor does not support wl_shm\n", .{});
            }
            if (self.layer_shell == null) {
                fatal("Wayland compositor does not support layer_shell\n", .{});
            }
            if (self.river_status_manager == null) {
                fatal("Wayland compositor does not support river_status_v1.\n", .{});
            }

            var it = self.outputs.first;
            while (it) |node| : (it = node.next) {
                if (!node.data.configured) node.data.getOutputStatus() catch return;
            }

            self.initialized = true;
        },
    }
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    log.err(format, args);
    std.os.exit(1);
}

test "timespec functions" {
    const testing = std.testing;
    const ts_a: os.timespec = .{ .tv_sec = 2, .tv_nsec = 500 };
    const ts_b: os.timespec = .{ .tv_sec = 3, .tv_nsec = 0 };
    var ts_c: os.timespec = undefined;
    ts_c = timespecDiff(&ts_b, &ts_a);
    const ns = timespecToNs(&ts_c);

    // 3s - (2s + 500ns) = 999999500ns
    try testing.expect(ns == 999_999_500);
}
