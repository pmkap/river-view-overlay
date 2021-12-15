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
const mem = std.mem;
const os = std.os;
const time = std.time;

const fcft = @import("fcft");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zriver = wayland.client.zriver;
const zwlr = wayland.client.zwlr;

const Config = @import("Config.zig");
const flags = @import("flags.zig");
const Output = @import("Output.zig");

const gpa = std.heap.c_allocator;
const log = std.log.scoped(.client);

const usage =
    \\Usage: agertu [options]
    \\
    \\  -h                           Print this help message and exit.
    \\
    \\  -surface-bg-color            [string] "0xRRGGBB" or "0xRRGGBBAA"
    \\  -surface-borders-color       [string] "0xRRGGBB" or "0xRRGGBBAA"
    \\  -surface-borders-size        [int] (Default 0)
    \\
    \\  -set-margins                 [string] Set the surface's margins
    \\                               "<top>:<right>:<bottom>:<left>"
    \\                               (Default: "0:10:10:0")
    \\  -set-anchors                 [string] Set the surface's anchors
    \\                               "<top>:<right>:<bottom>:<left>"
    \\                               (Default: "0:1:1:0")
    \\
    \\  -no-tags-text                Disable text number in tags
    \\  -tags-amount                 [int] (Default 9)
    \\  -tags-square-size            [int] (Default 50)
    \\  -tags-borders-size           [int] (Default 2)
    \\  -tags-margins                [int] (Default 5)
    \\  -tags-bg-color               [string] "0xRRGGBB" or "0xRRGGBBAA"
    \\  -tags-fg-color               [string] "0xRRGGBB" or "0xRRGGBBAA"
    \\  -tags-borders-color          [string] "0xRRGGBB" or "0xRRGGBBAA"
    \\  -tags-focused-bg-color       [string] "0xRRGGBB" or "0xRRGGBBAA"
    \\  -tags-focused-fg-color       [string] "0xRRGGBB" or "0xRRGGBBAA"
    \\  -tags-focused-borders-color  [string] "0xRRGGBB" or "0xRRGGBBAA"
    \\  -tags-occupied-bg-color      [string] "0xRRGGBB" or "0xRRGGBBAA"
    \\  -tags-occupied-fg-color      [string] "0xRRGGBB" or "0xRRGGBBAA"
    \\  -tags-occupied-borders-color [string] "0xRRGGBB" or "0xRRGGBBAA"
    \\  -tags-urgent-bg-color        [string] "0xRRGGBB" or "0xRRGGBBAA"
    \\  -tags-urgent-fg-color        [string] "0xRRGGBB" or "0xRRGGBBAA"
    \\  -tags-urgent-borders-color   [string] "0xRRGGBB" or "0xRRGGBBAA"
    \\
;

/// True when the client can dispatch events. This is set here so it can be
/// changed by signals handler.
var initialized: bool = false;

pub const Context = struct {
    display: *wl.Display,
    registry: *wl.Registry,
    callback_sync: ?*wl.Callback = null,

    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,

    layer_shell: ?*zwlr.LayerShellV1 = null,
    river_status_manager: ?*zriver.StatusManagerV1 = null,

    outputs: std.TailQueue(Output) = .{},

    config: Config = .{},

    pub fn init(ctx: *Context) !void {
        Signal.init();

        if (std.builtin.mode == .Debug) fcft.logInit(.auto, true, .debug);

        const display = wl.Display.connect(null) catch {
            std.debug.warn("Unable to connect to Wayland server.\n", .{});
            std.os.exit(1);
        };

        ctx.* = .{
            .display = display,
            .registry = try display.getRegistry(),
            .callback_sync = try display.sync(),
        };

        ctx.config = try ctx.setup();

        ctx.registry.setListener(*Context, registryListener, ctx);
        ctx.callback_sync.?.setListener(*Context, callbackListener, ctx);

        _ = try ctx.display.roundtrip();
    }

    pub fn destroy(ctx: *Context) void {
        while (ctx.outputs.pop()) |node| node.data.deinit();

        if (ctx.compositor) |compositor| compositor.destroy();
        if (ctx.shm) |shm| shm.destroy();
        if (ctx.layer_shell) |layer_shell| layer_shell.destroy();
        if (ctx.river_status_manager) |manager| manager.destroy();

        ctx.registry.destroy();
        ctx.display.disconnect();
    }

    pub fn setup(ctx: *Context) !Config {
        var config: Config = .{};

        // https://github.com/ziglang/zig/issues/7807
        const argv: [][*:0]const u8 = os.argv;
        const result = flags.parse(argv[1..], &[_]flags.Flag{
            .{ .name = "-h", .kind = .boolean },
            .{ .name = "-surface-bg-color", .kind = .arg },
            .{ .name = "-surface-borders-color", .kind = .arg },
            .{ .name = "-surface-borders-size", .kind = .arg },
            .{ .name = "-set-margins", .kind = .arg },
            .{ .name = "-set-anchors", .kind = .arg },
            .{ .name = "-no-tags-text", .kind = .boolean },
            .{ .name = "-tags-amount", .kind = .arg },
            .{ .name = "-tags-square-size", .kind = .arg },
            .{ .name = "-tags-borders-size", .kind = .arg },
            .{ .name = "-tags-margins", .kind = .arg },
            .{ .name = "-tags-bg-color", .kind = .arg },
            .{ .name = "-tags-fg-color", .kind = .arg },
            .{ .name = "-tags-borders-color", .kind = .arg },
            .{ .name = "-tags-focused-bg-color", .kind = .arg },
            .{ .name = "-tags-focused-fg-color", .kind = .arg },
            .{ .name = "-tags-focused-borders-color", .kind = .arg },
            .{ .name = "-tags-occupied-bg-color", .kind = .arg },
            .{ .name = "-tags-occupied-fg-color", .kind = .arg },
            .{ .name = "-tags-occupied-borders-color", .kind = .arg },
            .{ .name = "-tags-urgent-bg-color", .kind = .arg },
            .{ .name = "-tags-urgent-fg-color", .kind = .arg },
            .{ .name = "-tags-urgent-borders-color", .kind = .arg },
        }) catch {
            try std.io.getStdErr().writeAll(usage);
            os.exit(1);
        };
        if (result.args.len != 0) fatalPrintUsage("unknown option '{s}'", .{result.args[0]});

        if (result.boolFlag("-h")) {
            try std.io.getStdOut().writeAll(usage);
            os.exit(0);
        }
        if (result.argFlag("-surface-bg-color")) |raw| {
            config.surface_background_color = mem.span(raw);
        }
        if (result.argFlag("-surface-borders-color")) |raw| {
            config.surface_borders_color = mem.span(raw);
        }
        if (result.argFlag("-surface-borders-size")) |raw| {
            config.surface_borders_size = std.fmt.parseUnsigned(u16, mem.span(raw), 10) catch
                fatalPrintUsage("invalid value '{s}' provided to -surface-borders-size", .{raw});
        }
        if (result.argFlag("-set-anchors")) |raw| {
            config.layer_anchors = mem.span(raw);
        }
        if (result.argFlag("-set-margins")) |raw| {
            config.layer_margins = mem.span(raw);
        }
        if (result.boolFlag("-no-tags-text")) {
            config.tags_number_text = false;
        }
        if (result.argFlag("-tags-amount")) |raw| {
            config.tags_amount = std.fmt.parseUnsigned(u32, mem.span(raw), 10) catch
                fatalPrintUsage("invalid value '{s}' provided to -tags-amount", .{raw});
        }
        if (result.argFlag("-tags-square-size")) |raw| {
            config.tags_square_size = std.fmt.parseUnsigned(u16, mem.span(raw), 10) catch
                fatalPrintUsage("invalid value '{s}' provided to -tags-square-size", .{raw});
        }
        if (result.argFlag("-tags-borders-size")) |raw| {
            config.tags_borders_size = std.fmt.parseUnsigned(u16, mem.span(raw), 10) catch
                fatalPrintUsage("invalid value '{s}' provided to -tags-borders-size", .{raw});
        }
        if (result.argFlag("-tags-margins")) |raw| {
            config.surface_borders_size = std.fmt.parseUnsigned(u16, mem.span(raw), 10) catch
                fatalPrintUsage("invalid value '{s}' provided to -tags-margins", .{raw});
        }
        if (result.argFlag("-tags-bg-color")) |raw| {
            config.tags_background_color = mem.span(raw);
        }
        if (result.argFlag("-tags-fg-color")) |raw| {
            config.tags_foreground_color = mem.span(raw);
        }
        if (result.argFlag("-tags-borders-color")) |raw| {
            config.tags_border_colors = mem.span(raw);
        }
        if (result.argFlag("-tags-focused-bg-color")) |raw| {
            config.tags_focused_background_color = mem.span(raw);
        }
        if (result.argFlag("-tags-focused-fg-color")) |raw| {
            config.tags_focused_foreground_color = mem.span(raw);
        }
        if (result.argFlag("-tags-focused-borders-color")) |raw| {
            config.tags_focused_borders_color = mem.span(raw);
        }
        if (result.argFlag("-tags-occupied-bg-color")) |raw| {
            config.tags_occupied_background_color = mem.span(raw);
        }
        if (result.argFlag("-tags-occupied-fg-color")) |raw| {
            config.tags_occupied_foreground_color = mem.span(raw);
        }
        if (result.argFlag("-tags-occupied-borders-color")) |raw| {
            config.tags_occupied_borders_color = mem.span(raw);
        }
        if (result.argFlag("-tags-urgent-bg-color")) |raw| {
            config.tags_urgent_background_color = mem.span(raw);
        }
        if (result.argFlag("-tags-urgent-fg-color")) |raw| {
            config.tags_urgent_foreground_color = mem.span(raw);
        }
        if (result.argFlag("-tags-urgent-borders-color")) |raw| {
            config.tags_urgent_borders_color = mem.span(raw);
        }

        return config;
    }

    pub fn loop(ctx: *Context) !void {
        var timeout: i64 = -1;
        var when: os.timespec = undefined;
        var fds = [1]os.pollfd{
            .{
                .fd = ctx.display.getFd(),
                .events = os.POLLIN,
                .revents = undefined,
            },
        };

        while (initialized) {
            while ((try ctx.display.dispatchPending()) > 0) {
                _ = try ctx.display.flush();
            }

            var it = ctx.outputs.first;
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

            _ = try ctx.display.flush();

            _ = try os.poll(&fds, @intCast(i32, timeout));

            if ((fds[0].revents & os.POLLIN) != 0) {
                _ = try ctx.display.dispatch();
            }

            if ((fds[0].revents & os.POLLOUT) != 0) {
                _ = try ctx.display.flush();
            }
        }

        _ = try ctx.display.flush();

        ctx.destroy();
    }

    fn addOutput(ctx: *Context, registry: *wl.Registry, name: u32) !void {
        const wl_output = try registry.bind(name, wl.Output, 3);
        errdefer wl_output.release();

        const node = try gpa.create(std.TailQueue(Output).Node);
        errdefer gpa.destroy(node);
        try node.data.init(ctx, wl_output, name);
        ctx.outputs.append(node);

        if (ctx.river_status_manager) |_| {
            try node.data.getOutputStatus();
        }
    }

    fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, ctx: *Context) void {
        switch (event) {
            .global => |global| {
                if (std.cstr.cmp(global.interface, wl.Compositor.getInterface().name) == 0) {
                    ctx.compositor = registry.bind(global.name, wl.Compositor, 4) catch return;
                } else if (std.cstr.cmp(global.interface, wl.Shm.getInterface().name) == 0) {
                    ctx.shm = registry.bind(global.name, wl.Shm, 1) catch return;
                } else if (std.cstr.cmp(global.interface, wl.Output.getInterface().name) == 0) {
                    ctx.addOutput(registry, global.name) catch |err| {
                        fatal("Failed to bind output: {}", .{err});
                    };
                } else if (std.cstr.cmp(global.interface, zwlr.LayerShellV1.getInterface().name) == 0) {
                    ctx.layer_shell = registry.bind(global.name, zwlr.LayerShellV1, 4) catch return;
                } else if (std.cstr.cmp(global.interface, zriver.StatusManagerV1.getInterface().name) == 0) {
                    ctx.river_status_manager = registry.bind(global.name, zriver.StatusManagerV1, 2) catch return;
                }
            },
            .global_remove => |ev| {
                var it = ctx.outputs.first;
                while (it) |node| : (it = node.next) {
                    const output = &node.data;
                    if (output.name == ev.name) {
                        ctx.outputs.remove(node);
                        output.deinit();
                        break;
                    }
                }
            },
        }
    }

    fn callbackListener(callback: *wl.Callback, event: wl.Callback.Event, ctx: *Context) void {
        switch (event) {
            .done => {
                callback.destroy();
                ctx.callback_sync = null;

                if (ctx.compositor == null) {
                    fatal("Wayland compositor does not support wl_compositor\n", .{});
                }
                if (ctx.shm == null) {
                    fatal("Wayland compositor does not support wl_shm\n", .{});
                }
                if (ctx.layer_shell == null) {
                    fatal("Wayland compositor does not support layer_shell\n", .{});
                }
                if (ctx.river_status_manager == null) {
                    fatal("Wayland compositor does not support river_status_v1.\n", .{});
                }

                var it = ctx.outputs.first;
                while (it) |node| : (it = node.next) {
                    const output = &node.data;
                    if (!output.configured) output.getOutputStatus() catch return;
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

/// POSIX signal handling.
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

fn fatalPrintUsage(comptime format: []const u8, args: anytype) noreturn {
    log.err(format, args);
    std.io.getStdErr().writeAll(usage) catch {};
    os.exit(1);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    log.err(format, args);
    os.exit(1);
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
