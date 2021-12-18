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

wl_output: *wl.Output,
name: u32,

ctx: *Context,
surface: ?*Surface = null,

river_output_status: *zriver.OutputStatusV1 = undefined,

font: *fcft.Font = undefined,

focused_tags: u32 = 0,
view_tags: u32 = 0,
urgent_tags: u32 = 0,

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

/// If a surface alreadu exists use it, else initialize a new one.
pub fn updateSurface(output: *Output) !void {
    if (output.surface) |surface| {
        log.debug("Surface available, using it", .{});
        try output.renderFrame();
    } else {
        log.debug("No Surface available, creating one", .{});
        const surface = try gpa.create(Surface);
        errdefer gpa.destroy(surface);
        output.surface = surface;
        try output.surface.?.init(output);
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
    try renderer.renderBorderedRectangle(
        image,
        0,
        0,
        @intCast(u16, buffer.width),
        @intCast(u16, buffer.height),
        config.surface_borders_size,
        config.surface_background_color,
        config.surface_borders_color,
    );

    // Render the tags square.
    try output.renderTags(
        image,
        config.tags_square_size,
        config.tags_borders_size,
        config.tags_margins,
    );

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

/// Render a bordered square for each tags with or without a number
/// text inside it.
fn renderTags(
    output: *Output,
    image: *pixman.Image,
    square_size: u16,
    borders_size: u16,
    margins: u16,
) !void {
    const config = output.ctx.config;

    var i: u32 = 0;
    while (i < config.tags_amount) : (i += 1) {
        // Tags state.
        const focused = if ((output.focused_tags & (@as(u32, 1) << @intCast(u5, i))) != 0) true else false;
        const urgent = if ((output.urgent_tags & (@as(u32, 1) << @intCast(u5, i))) != 0) true else false;
        const occupied = if ((output.view_tags & (@as(u32, 1) << @intCast(u5, i))) != 0) true else false;

        const tag_background_color = blk: {
            if (focused) break :blk config.tags_focused_background_color;
            if (urgent) break :blk config.tags_urgent_background_color;
            if (occupied) break :blk config.tags_occupied_background_color;
            break :blk config.tags_background_color;
        };

        const tag_borders_color = blk: {
            if (focused) break :blk config.tags_focused_borders_color;
            if (urgent) break :blk config.tags_urgent_borders_color;
            if (occupied) break :blk config.tags_occupied_borders_color;
            break :blk config.tags_border_colors;
        };

        // Total size of a tag.
        const tag_width: u32 = square_size + margins;

        // Starting point of all tags.
        const x_start: i16 = @intCast(i16, config.surface_borders_size + margins);
        // Starting point of each tag square.
        const x_square: i16 = x_start + @intCast(i16, i * tag_width);

        // Render the bordered square.
        try renderer.renderBorderedRectangle(
            image,
            x_square,
            x_start,
            square_size,
            square_size,
            borders_size,
            tag_background_color,
            tag_borders_color,
        );

        // Render the tag number inside the square.
        if (config.tags_number_text) {
            const x_text: i16 = x_start + @intCast(i16, margins + borders_size + i * tag_width);
            const y_text: i16 = @intCast(i16, config.surface_borders_size + tag_width / 2);

            const foreground = blk: {
                if (focused) break :blk config.tags_focused_foreground_color;
                if (urgent) break :blk config.tags_urgent_foreground_color;
                if (occupied) break :blk config.tags_occupied_foreground_color;
                break :blk config.tags_foreground_color;
            };

            var buf: [2]u8 = undefined;
            var tag_number = try fmt.bufPrint(&buf, "{}", .{i + 1});
            try renderer.renderBytes(
                image,
                tag_number,
                output.font,
                foreground,
                x_text,
                y_text,
            );
        }
    }
}

fn handleFocusedTags(output: *Output, tags: u32) void {
    output.focused_tags = tags;
    output.updateSurface() catch return;
}

fn handleViewTags(output: *Output, tags: *wl.Array) void {
    output.view_tags = 0;
    for (tags.slice(u32)) |tag| {
        output.view_tags |= tag;
    }
    // Only update if the Surface already exists.
    if (output.surface != null) output.updateSurface() catch return;
}

fn handleUrgentTags(output: *Output, tags: u32) void {
    const old_tags = output.urgent_tags;
    output.urgent_tags = tags;
    // Only display the popup if the urgent tags are not already focused.
    if (output.urgent_tags != output.focused_tags) {
        // Only display the popup when tags become urgent, not when
        // it loses urgency.
        const diff = old_tags ^ output.urgent_tags;
        if ((diff & output.urgent_tags) > 0) {
            output.updateSurface() catch return;
        }
    }
}

fn outputStatuslistener(
    river_output_status: *zriver.OutputStatusV1,
    event: zriver.OutputStatusV1.Event,
    output: *Output,
) void {
    switch (event) {
        .focused_tags => |ev| output.handleFocusedTags(ev.tags),
        .view_tags => |ev| output.handleViewTags(ev.tags),
        .urgent_tags => |ev| output.handleUrgentTags(ev.tags),
    }
}
