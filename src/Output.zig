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
const os = std.os;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zriver = wayland.client.zriver;
const pixman = @import("pixman");
const fcft = @import("fcft");

const Buffer = @import("shm.zig").Buffer;
const BufferStack = @import("shm.zig").BufferStack;
const Context = @import("client.zig").Context;
const Surface = @import("Surface.zig");
const renderer = @import("renderer.zig");

const gpa = std.heap.c_allocator;
const log = std.log.scoped(.output);

const Output = @This();

const View = struct {
    app_id: [*:0]const u8,
    title: [*:0]const u8,
    focused: bool,
};

wl_output: *wl.Output,
name: u32,

ctx: *Context,
surface: ?*Surface = null,

river_output_status: *zriver.OutputStatusV1 = undefined,

font: *fcft.Font = undefined,

focused_tags: u32 = 0,
view_tags: u32 = 0,
urgent_tags: u32 = 0,

views: std.TailQueue(View) = .{},

configured: bool = false,

pub fn init(output: *Output, ctx: *Context, wl_output: *wl.Output, name: u32) !void {
    // TODO: Should be configurable in Config.zig.
    var font_names = [_][*:0]const u8{"monospace:size=18"};
    const font = try fcft.Font.fromName(font_names[0..], null);
    errdefer font.destroy();

    output.* = .{
        .wl_output = wl_output,
        .name = name,
        .ctx = ctx,
        .font = font,
    };
}

pub fn deinit(output: *Output) void {
    if (output.surface) |surface| surface.destroy();
    output.font.destroy();
    output.river_output_status.destroy();
    output.wl_output.release();

    const node = @fieldParentPtr(std.TailQueue(Output).Node, "data", output);
    gpa.destroy(node);
}

pub fn getOutputStatus(output: *Output) !void {
    output.river_output_status = try output.ctx.river_status_manager.?.getRiverOutputStatus(output.wl_output);
    output.river_output_status.setListener(*Output, outputStatuslistener, output);
    output.configured = true;
}

/// If a surface already exists use it, else initialize a new one.
pub fn updateSurface(output: *Output, width: u32, height: u32) !void {
    if (output.surface) |surface| {
        log.debug("Surface available, using it", .{});
        surface.setSize(width, height);
        try output.renderFrame();
    } else {
        log.debug("No Surface available, creating one", .{});
        const surface = try gpa.create(Surface);
        errdefer gpa.destroy(surface);
        output.surface = surface;
        try output.surface.?.init(output, width, height);
    }
}

/// Return true if Buffer is not busy.
fn notBusyFilter(buffer: *Buffer, context: void) bool {
    return !buffer.busy;
}

// TODO: Could be improved, not sure if double buffering works as expected.
/// Return the next Buffer not busy or create a new one if none
/// are available.
pub fn getNextBuffer(output: *Output) !*Buffer {
    const surface = output.surface.?;
    var it = BufferStack(Buffer).iter(surface.buffer_stack.first, .forward, {}, notBusyFilter);
    while (it.next()) |buf| {
        if (buf.width != surface.width or buf.height != surface.height) {
            buf.destroy();
            try buf.init(output.ctx.shm.?, surface.width, surface.height);
        }
        log.debug("Buffer available, using it", .{});
        return buf;
    }

    log.debug("No Buffer available, creating one", .{});
    const new_buffer_node = try gpa.create(BufferStack(Buffer).Node);
    try new_buffer_node.buffer.init(output.ctx.shm.?, surface.width, surface.height);
    surface.buffer_stack.append(new_buffer_node);
    return &new_buffer_node.buffer;
}

/// Draw and commit a frame.
pub fn renderFrame(output: *Output) !void {
    const config = output.ctx.config;
    const surface = output.surface.?;
    if (!surface.configured) {
        log.debug("Surface is not configured.", .{});
        return;
    }

    const buffer = try output.getNextBuffer();
    const image = buffer.pixman_image orelse return;

    // Now the surface is configured and has a buffer, we can safely draw on it.
    // Then attach to the buffer, damage the buffer and finally commit our surface.
    //
    // Render the background surface.
    //try renderer.renderBorderedRectangle(
    //    image,
    //    0,
    //    0,
    //    @intCast(u16, buffer.width),
    //    @intCast(u16, buffer.height),
    //    config.surface_borders_size,
    //    "0x0000ff",
    //    config.surface_borders_color,
    //);

    // Render views
    try output.renderViews(image);

    if (surface.wl_surface) |wl_surface| {
        wl_surface.attach(buffer.wl_buffer, 0, 0);
        wl_surface.damageBuffer(
            0,
            0,
            @intCast(i32, buffer.width),
            @intCast(i32, buffer.height),
        );
    }

    buffer.busy = true;

    var now: os.timespec = undefined;
    os.clock_gettime(os.CLOCK_MONOTONIC, &now) catch @panic("CLOCK_MONOTONIC not supported");
    surface.last_frame = now;

    surface.wl_surface.?.commit();
}

fn renderViews(output: *Output, image: *pixman.Image) !void {
    var i: i16 = 0;
    var it = output.views.first;
    while (it) |node| : (it = node.next) {
        // Render the bordered square.
        try renderer.renderBorderedRectangle(
            image,
            0,
            i * 30,
            300,
            30,
            output.ctx.config.tags_borders_size,
            "0x000000",
            if (node.data.focused) "0xffff00" else "0x000000",
        );
        // Render text
        var buf: [100]u8 = undefined;
        var view_title = try fmt.bufPrint(&buf, "{s}", .{node.data.title});
        try renderer.renderBytes(
            image,
            view_title,
            output.font,
            "0xffffff",
            0,
            i * 30,
        );

        i += 1;
    }
}

fn handleFocusedTags(output: *Output, tags: u32) void {
    output.focused_tags = tags;
}

fn handleViewsBegin(output: *Output) void {
    // for now only do something on tag 1
    if (output.focused_tags != 1) return;

    // cleanup views
    while (output.views.pop()) |node| {
        std.heap.c_allocator.destroy(node);
    }
}

fn handleView(output: *Output, app_id: [*:0]const u8, title: [*:0]const u8, focused: u32) void {
    // for now only do something on tag 1
    if (output.focused_tags != 1) return;

    const view = View{
        .app_id = app_id,
        .title = title,
        .focused = if (focused == 0) false else true,
    };
    const node = std.heap.c_allocator.create(std.TailQueue(View).Node) catch return;
    node.data = view;
    output.views.append(node);
}

fn handleViewsDone(output: *Output) void {
    // for now only do something on tag 1
    if (output.focused_tags != 1) return;

    const num_views = @intCast(u32, output.views.len);
    if (num_views == 0) return;

    output.updateSurface(300, 30 * num_views) catch return;
}

fn outputStatuslistener(
    river_output_status: *zriver.OutputStatusV1,
    event: zriver.OutputStatusV1.Event,
    output: *Output,
) void {
    switch (event) {
        .focused_tags => |ev| output.handleFocusedTags(ev.tags),
        .view => |ev| output.handleView(ev.app_id, ev.title, ev.focused),
        .views_done => |ev| output.handleViewsDone(),
        .views_begin => |ev| output.handleViewsBegin(),
        else => {},
    }
}
