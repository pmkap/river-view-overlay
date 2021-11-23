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

const Self = @This();

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

pub fn init(self: *Self, ctx: *Context, output: *wl.Output, name: u32) !void {
    // TODO: Should be configurable in Config.zig.
    var font_names = [_][*:0]const u8{"monospace:size=18"};
    const font = try fcft.Font.fromName(font_names[0..], null);
    errdefer font.destroy();

    self.* = .{
        .wl_output = output,
        .name = name,
        .ctx = ctx,
        .font = font,
    };
}

pub fn deinit(self: *Self) void {
    if (self.surface) |surface| surface.destroy();

    self.font.destroy();
    self.river_output_status.destroy();
    self.wl_output.release();

    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
    gpa.destroy(node);
}

pub fn getOutputStatus(self: *Self) !void {
    self.river_output_status = try self.ctx.river_status_manager.?.getRiverOutputStatus(self.wl_output);
    self.river_output_status.setListener(*Self, outputStatuslistener, self);
    self.configured = true;
}

/// If a surface alreadu exists use it, else initialize a new one.
pub fn updateSurface(self: *Self) !void {
    if (self.surface) |surface| {
        log.debug("Surface found, using it", .{});
        try self.renderFrame();
    } else {
        log.debug("No Surface found, creating one", .{});
        const surface = try gpa.create(Surface);
        errdefer gpa.destroy(surface);
        self.surface = surface;
        try self.surface.?.init(self);
    }
}

fn notBusyFilter(buffer: *Buffer, context: void) bool {
    return buffer.busy == false;
}

pub fn getNextBuffer(self: *Self) !*Buffer {
    const surface = self.surface.?;
    var ret: ?*Buffer = null;
    var it = BufferStack(*Buffer).iter(surface.buffer_stack.first, .forward, {}, notBusyFilter);
    while (it.next()) |buf| {
        if (buf.width != surface.width or buf.height != surface.height or
            buf.wl_buffer == null)
        {
            buf.destroy();
            ret = null;
            break;
        }
        ret = buf;
    }

    if (ret == null) {
        log.debug("No Buffer available, creating one", .{});
        const new_buffer_node = try gpa.create(BufferStack(*Buffer).Node);
        ret = try Buffer.create(self.ctx.shm.?, surface.width, surface.height);
        new_buffer_node.buffer = ret.?;
        surface.buffer_stack.append(new_buffer_node);
    }

    return ret.?;
}

/// Draw and commit a frame.
pub fn renderFrame(self: *Self) !void {
    const config = self.ctx.config;
    const surface = self.surface.?;
    if (!surface.configured) {
        log.debug("Surface is not configured.", .{});
        return;
    }

    const buffer = try self.getNextBuffer();
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
        &config.surface_color_background,
        &config.surface_color_borders,
    );

    // Render the tags square.
    try self.renderTags(
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
    surface.last_frame = &now;

    surface.wl_surface.?.commit();
}

/// Render a bordered square for each tags with or without a number
/// text inside it.
fn renderTags(
    self: *Self,
    image: *pixman.Image,
    square_size: u16,
    borders_size: u16,
    margins: u16,
) !void {
    const config = self.ctx.config;

    var i: u32 = 0;
    while (i < config.tags_amount) : (i += 1) {
        // Tags state.
        const focused = if ((self.focused_tags & (@as(u32, 1) << @intCast(u5, i))) != 0) true else false;
        const urgent = if ((self.urgent_tags & (@as(u32, 1) << @intCast(u5, i))) != 0) true else false;
        const occupied = if ((self.view_tags & (@as(u32, 1) << @intCast(u5, i))) != 0) true else false;

        const tag_background_color = blk: {
            if (focused) break :blk &config.tags_color_focused;
            if (urgent) break :blk &config.tags_color_urgent;
            if (occupied) break :blk &config.tags_color_occupied;
            break :blk &config.tags_color_background;
        };

        const tag_borders_color = blk: {
            if (focused) break :blk &config.tags_color_borders_focused;
            if (urgent) break :blk &config.tags_color_borders_urgent;
            if (occupied) break :blk &config.tags_color_borders_occupied;
            break :blk &config.tags_color_borders;
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
                if (focused) break :blk &config.tags_color_foreground_focused;
                if (urgent) break :blk &config.tags_color_foreground_urgent;
                if (occupied) break :blk &config.tags_color_foreground_occupied;
                break :blk &config.tags_color_foreground;
            };

            var buf: [2]u8 = undefined;
            var tag_number = try std.fmt.bufPrint(&buf, "{}", .{i + 1});
            try renderer.renderBytes(
                image,
                tag_number,
                self.font,
                foreground,
                borders_size,
                x_text,
                y_text,
            );
        }
    }
}

fn handleFocusedTags(self: *Self, tags: u32) void {
    self.focused_tags = tags;
    self.updateSurface() catch return;
}

fn handleViewTags(self: *Self, tags: *wl.Array) void {
    for (tags.slice(u32)) |tag| {
        self.view_tags |= tag;
    }
    // Only update if the Surface already exists.
    if (self.surface != null) self.updateSurface() catch return;
}

fn handleUrgentTags(self: *Self, tags: u32) void {
    self.urgent_tags = tags;
    self.updateSurface() catch return;
}

fn outputStatuslistener(
    river_output_status: *zriver.OutputStatusV1,
    event: zriver.OutputStatusV1.Event,
    self: *Self,
) void {
    switch (event) {
        .focused_tags => |ev| self.handleFocusedTags(ev.tags),
        .view_tags => |ev| self.handleViewTags(ev.tags),
        .urgent_tags => |ev| self.handleUrgentTags(ev.tags),
    }
}
