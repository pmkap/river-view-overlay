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

/// True when the client can dispatch events. This is set here so it can be
/// changed by signals handler.
var initialized: bool = false;

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

    pub fn init(self: *Self) !void {
        Signal.init();

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
        while (self.outputs.pop()) |node| node.data.deinit();

        if (self.compositor) |compositor| compositor.destroy();
        if (self.shm) |shm| shm.destroy();
        if (self.layer_shell) |layer_shell| layer_shell.destroy();
        if (self.river_status_manager) |manager| manager.destroy();

        self.registry.destroy();
        self.display.disconnect();
    }

    pub fn loop(self: *Self) !void {
        var timeout: i64 = -1;
        var when: os.timespec = undefined;
        var fds = [1]os.pollfd{
            .{
                .fd = self.display.getFd(),
                .events = os.POLLIN,
                .revents = undefined,
            },
        };

        while (initialized) {
            while ((try self.display.dispatchPending()) > 0) {
                _ = try self.display.flush();
            }

            var it = self.outputs.first;
            while (it) |node| : (it = node.next) {
                const output = &node.data;
                if (output.surface) |surface| {
                    if (!surface.configured) continue;

                    var now: os.timespec = undefined;
                    os.clock_gettime(os.CLOCK_MONOTONIC, &now) catch @panic("CLOCK_MONOTONIC not supported");

                    timespecDiff(&now, &surface.last_frame, &when);
                } else continue;

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
                        if (timeout == -1 or timeout > _timeout) break :blk @intCast(i32, _timeout);
                        break :blk timeout;
                    };
                }
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

        _ = try self.display.flush();

        self.destroy();
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
                    const output = &node.data;
                    if (output.name == ev.name) {
                        self.outputs.remove(node);
                        output.deinit();
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

                initialized = true;
            },
        }
    }

    fn timespecDiff(ts1: *const os.timespec, ts2: *const os.timespec, result: *os.timespec) void {
        if ((ts1.tv_nsec - ts2.tv_nsec) < 0) {
            result.* = .{
                .tv_sec = (ts1.tv_sec - ts2.tv_sec) - 1,
                .tv_nsec = (ts1.tv_nsec - ts2.tv_nsec) + time.ns_per_s,
            };
        } else result.* = .{
            .tv_sec = ts1.tv_sec - ts2.tv_sec,
            .tv_nsec = ts1.tv_nsec - ts2.tv_nsec,
        };
    }
};

// POSIX signal handling.
pub const Signal = struct {
    fn init() void {
        var mask = os.empty_sigset;
        const sigaddset = os.linux.sigaddset;

        sigaddset(&mask, os.SIGTERM);
        os.sigaction(
            os.SIGTERM,
            &os.Sigaction{ .handler = .{ .sigaction = handler }, .mask = mask, .flags = os.SA_SIGINFO },
            null,
        );

        sigaddset(&mask, os.SIGINT);
        os.sigaction(
            os.SIGINT,
            &os.Sigaction{ .handler = .{ .sigaction = handler }, .mask = mask, .flags = os.SA_SIGINFO },
            null,
        );
    }

    fn handler(signal: c_int, info: *const os.siginfo_t, data: ?*const c_void) callconv(.C) void {
        // Reset sigaction to default in case of multiple signals.
        const sigaction_reset = os.Sigaction{
            .handler = .{ .sigaction = os.SIG_DFL },
            .mask = os.empty_sigset,
            .flags = os.SA_SIGINFO,
        };

        switch (signal) {
            os.SIGTERM => {
                log.warn("Terminated by signal SIGTERM", .{});
                initialized = false;

                os.sigaction(os.SIGTERM, &sigaction_reset, null);
            },
            os.SIGINT => {
                log.warn("Terminated by signal SIGINT", .{});
                initialized = false;

                os.sigaction(os.SIGINT, &sigaction_reset, null);
            },
            else => {},
        }
    }
};

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    log.err(format, args);
    std.os.exit(1);
}

test "timespec functions" {
    const testing = std.testing;
    const ts_a: os.timespec = .{ .tv_sec = 2, .tv_nsec = 500 };
    const ts_b: os.timespec = .{ .tv_sec = 3, .tv_nsec = 0 };
    var ts_c: os.timespec = undefined;
    Context.timespecDiff(&ts_b, &ts_a, &ts_c);

    // 3s - (2s + 500ns) = 999999500ns
    try testing.expect(ts_c.tv_sec == 0);
    try testing.expect(ts_c.tv_nsec == 999999500);
}
