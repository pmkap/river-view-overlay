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
const fmt = std.fmt;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;
const pixman = @import("pixman");
const fcft = @import("fcft");

const gpa = std.heap.c_allocator;
const log = std.log.scoped(.agertu);

const Self = @This();

// TODO:
// This should be configurable at least with command line args and ideally
// later with a config file in XDG_CONFIG_HOME/agertu/init
//
// It would be easier to let the user changes the colors if we use a
// []const u8 instead of parsing it directly here

// Surface
surface_borders_size: u16 = 0,

surface_color_background: pixman.Color = try parseRgba("0x202325"),
surface_color_borders: pixman.Color = try parseRgba("0x9e2f59"),

// Tags
tags_amount: u32 = 9,
tags_square_size: u16 = 50,
tags_borders_size: u16 = 2,
tags_margins: u16 = 5,

tags_color_background: pixman.Color = try parseRgba("0x3a4043"),
tags_color_borders: pixman.Color = try parseRgba("0x646e73"),

tags_color_focused: pixman.Color = try parseRgba("0xf9f9fa"),
tags_color_borders_focused: pixman.Color = try parseRgba("0xdce1e4"),

tags_color_occupied: pixman.Color = try parseRgba("0x2e3f9f"),
tags_color_borders_occupied: pixman.Color = try parseRgba("0xdbf1fd"),

tags_color_urgent: pixman.Color = try parseRgba("0x9e2f59"),
tags_color_borders_urgent: pixman.Color = try parseRgba("0xfde7f6"),

tags_number_text: bool = true,
tags_color_foreground: pixman.Color = try parseRgba("0xdce1e4"),
tags_color_foreground_focused: pixman.Color = try parseRgba("0x202325"),
tags_color_foreground_occupied: pixman.Color = try parseRgba("0xdce1e4"),
tags_color_foreground_urgent: pixman.Color = try parseRgba("0x202325"),

/// Parse a color in the format 0xRRGGBB or 0xRRGGBBAA
fn parseRgba(string: []const u8) !pixman.Color {
    if (string.len != 8 and string.len != 10) return error.InvalidRgba;
    if (string[0] != '0' or string[1] != 'x') return error.InvalidRgba;

    const r = try fmt.parseInt(u8, string[2..4], 16);
    const g = try fmt.parseInt(u8, string[4..6], 16);
    const b = try fmt.parseInt(u8, string[6..8], 16);
    const a = if (string.len == 10) try fmt.parseInt(u8, string[8..10], 16) else 255;

    const alpha = @floatToInt(u16, (@intToFloat(f32, a) / 255.0) * 65535.0);
    const red = @floatToInt(u16, ((@intToFloat(f32, r) / 255.0) * 65535.0) * @intToFloat(f32, alpha) / 0xffff);
    const green = @floatToInt(u16, ((@intToFloat(f32, g) / 255.0) * 65535.0) * @intToFloat(f32, alpha) / 0xffff);
    const blue = @floatToInt(u16, ((@intToFloat(f32, b) / 255.0) * 65535.0) * @intToFloat(f32, alpha) / 0xffff);

    return pixman.Color{
        .red = red,
        .green = green,
        .blue = blue,
        .alpha = alpha,
    };
}

// TODO
/// Parse a string in the format "top:right:bottom:left", e.g. "1:1:0:0".
fn parseAnchors(string: []const u8) !zwlr.LayerSurfaceV1.Anchor {
    if (string.len != 7) return error.InvalidAnchors;

    const top = try fmt.parseInt(u8, string[0..1], 16);
    const right = try fmt.parseInt(u8, string[2..3], 16);
    const bottom = try fmt.parseInt(u8, string[4..5], 16);
    const left = try fmt.parseInt(u8, string[8..7], 16);

    return zwlr.LayerSurfaceV1.Anchor{
        .top = top,
        .right = right,
        .bottom = bottom,
        .left = left,
    };
}
