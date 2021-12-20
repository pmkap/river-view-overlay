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
const fmt = std.fmt;
const mem = std.mem;
const os = std.os;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const Buffer = @import("shm.zig").Buffer;
const BufferStack = @import("shm.zig").BufferStack;
const Context = @import("client.zig").Context;
const Output = @import("Output.zig");

const gpa = std.heap.c_allocator;
const log = std.log.scoped(.surface);

const Surface = @This();

wl_surface: ?*wl.Surface,
layer_surface: ?*zwlr.LayerSurfaceV1,

buffer_stack: BufferStack(Buffer) = .{},

width: u32 = 0,
height: u32 = 0,

/// Time when the wl_surface is commited.
last_frame: os.timespec = undefined,

/// True once the layer_surface received the configure event.
configured: bool = false,

pub fn init(surface: *Surface, output: *Output, width: u32, height: u32) !void {
    const config = output.ctx.config;

    const wl_surface = try output.ctx.compositor.?.createSurface();
    const layer_surface = try output.ctx.layer_shell.?.getLayerSurface(
        wl_surface,
        output.wl_output,
        .overlay,
        "agertu",
    );

    surface.* = .{
        .wl_surface = wl_surface,
        .layer_surface = layer_surface,
        .width = width,
        .height = height,
    };

    // Configure the layer_surface.
    if (surface.layer_surface) |layer| {
        layer.setListener(*Output, layerSurfaceListener, output);
        layer.setSize(surface.width, surface.height);
        layer.setAnchor(try parseAnchors(config.layer_anchors));
        const margins = try parseMargins(config.layer_margins);
        layer.setMargin(margins[0], margins[1], margins[2], margins[3]);
    }

    // Create an empty region so the compositor knows that the surface is not
    // interested in pointer events.
    const region = try output.ctx.compositor.?.createRegion();
    surface.wl_surface.?.setInputRegion(region);
    region.destroy();

    // We need to commit the empty surface first so we can receive a configure event
    // with width and height requested for our surface.
    surface.wl_surface.?.commit();

    log.debug("New Surface initialized", .{});
}

pub fn destroy(surface: *Surface) void {
    if (surface.layer_surface) |layer_surface| layer_surface.destroy();
    if (surface.wl_surface) |wl_surface| wl_surface.destroy();

    while (surface.buffer_stack.first) |node| {
        node.buffer.destroy();
        surface.buffer_stack.remove(node);
        gpa.destroy(node);
        log.debug("Buffer destroyed", .{});
    }

    gpa.destroy(surface);
    log.debug("Surface destroyed", .{});
}

pub fn setSize(surface: *Surface, width: u32, height: u32) void {
    surface.width = width;
    surface.height = height;
    (surface.layer_surface orelse return).setSize(width, height);
}

fn layerSurfaceListener(
    layer_surface: *zwlr.LayerSurfaceV1,
    event: zwlr.LayerSurfaceV1.Event,
    output: *Output,
) void {
    const surface = output.surface.?;
    switch (event) {
        .configure => |data| {
            surface.configured = true;
            surface.width = data.width;
            surface.height = data.height;
            surface.layer_surface.?.ackConfigure(data.serial);

            // Once we receive the configure event, the surface is
            // configured and we can safely draw on our surface.
            output.renderFrame() catch return;
        },
        .closed => {
            surface.destroy();
            output.surface = null;
        },
    }
}

/// Parse a string in the format "top:right:bottom:left", e.g. "1:1:0:0".
fn parseAnchors(string: []const u8) !zwlr.LayerSurfaceV1.Anchor {
    if (string.len != 7) return error.InvalidAnchors;

    if (string[1] != ':' or string[3] != ':' or string[5] != ':') return error.InvalidAnchors;

    if (string[0] != '0' and string[0] != '1') return error.InvalidAnchors;
    if (string[2] != '0' and string[2] != '1') return error.InvalidAnchors;
    if (string[4] != '0' and string[4] != '1') return error.InvalidAnchors;
    if (string[6] != '0' and string[6] != '1') return error.InvalidAnchors;

    return zwlr.LayerSurfaceV1.Anchor{
        .top = string[0] == '1',
        .right = string[2] == '1',
        .bottom = string[4] == '1',
        .left = string[6] == '1',
    };
}

/// Parse a string in the format "top:right:bottom:left", e.g. "10:5:0:0".
fn parseMargins(string: []const u8) ![4]i32 {
    var str = mem.tokenize(string, ":");
    var ret: [4]i32 = .{ 0, 0, 0, 0 };
    var i: usize = 0;
    while (str.next()) |anchor| : (i += 1) {
        ret[i] = try fmt.parseInt(i32, anchor, 10);
    }

    return [4]i32{ ret[0], ret[1], ret[2], ret[3] };
}
