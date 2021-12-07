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

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const Buffer = @import("shm.zig").Buffer;
const BufferStack = @import("shm.zig").BufferStack;
const Context = @import("client.zig").Context;
const Output = @import("Output.zig");

const gpa = std.heap.c_allocator;
const log = std.log.scoped(.surface);

const Self = @This();

wl_surface: ?*wl.Surface,
layer_surface: ?*zwlr.LayerSurfaceV1,

buffer_stack: BufferStack(Buffer) = .{},

width: u32 = 0,
height: u32 = 0,

/// Time when the wl_suurface is commited.
last_frame: *os.timespec = undefined,

/// True once the layer_surface received the configure event.
configured: bool = false,

pub fn init(self: *Self, output: *Output) !void {
    const config = output.ctx.config;

    const wl_surface = try output.ctx.compositor.?.createSurface();
    const layer_surface = try output.ctx.layer_shell.?.getLayerSurface(
        wl_surface,
        output.wl_output,
        .overlay,
        "agertu",
    );

    self.* = .{
        .wl_surface = wl_surface,
        .layer_surface = layer_surface,
        .width = config.tags_amount * config.tags_square_size +
            (config.tags_amount + 1) * config.tags_margins + 2 * config.surface_borders_size,
        // "1" for now and will change if some things are added later.
        .height = 1 * (config.tags_square_size + 2 * config.tags_margins) +
            (2 * config.surface_borders_size),
    };

    // Configure the layer_surface.
    if (self.layer_surface) |layer| {
        layer.setListener(*Output, layerSurfaceListener, output);
        layer.setSize(self.width, self.height);
        // TODO: Set it in Config.zig
        layer.setAnchor(.{ .top = true, .left = false, .bottom = false, .right = true });
        layer.setMargin(10, 10, 0, 0);
    }

    // Create an empty region so the compositor knows that the surface is not
    // interested in pointer events.
    const region = try output.ctx.compositor.?.createRegion();
    self.wl_surface.?.setInputRegion(region);
    region.destroy();

    // We need to commit the empty surface first so we can receive a configure event
    // with width and height requested for our surface.
    self.wl_surface.?.commit();

    log.debug("New Surface initialized", .{});
}

pub fn destroy(self: *Self) void {
    if (self.layer_surface) |layer_surface| layer_surface.destroy();
    if (self.wl_surface) |wl_surface| wl_surface.destroy();

    while (self.buffer_stack.first) |node| {
        node.buffer.destroy();
        self.buffer_stack.remove(node);
        gpa.destroy(node);
        log.debug("Buffer destroyed", .{});
    }

    gpa.destroy(self);
    log.debug("Surface destroyed", .{});
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
