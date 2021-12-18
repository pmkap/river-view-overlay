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

const flags = @import("flags.zig");
const log = std.log.scoped(.config);

const Config = @This();

const usage =
    \\Usage: agertu [options]
    \\
    \\  -h                           Print this help message and exit.
    \\
    \\  -surface-bg-color            <hex> 0xRRGGBB or 0xRRGGBBAA
    \\  -surface-borders-color       <hex> 0xRRGGBB or 0xRRGGBBAA
    \\  -surface-borders-size        <int> (Default 0)
    \\
    \\  -set-margins                 <int>:<int>:<int>:<int>
    \\                               <top>:<right>:<bottom>:<left>
    \\                               Set the surface's margins
    \\                               (Default: 0:10:10:0)
    \\  -set-anchors                 <int>:<int>:<int>:<int>
    \\                               <top>:<right>:<bottom>:<left>
    \\                                Set the surface's anchors
    \\                               (Default: 0:1:1:0)
    \\
    \\  -no-tags-text                Disable text number in tags
    \\  -tags-amount                 <int> (Default 9)
    \\  -tags-square-size            <int> (Default 50)
    \\  -tags-borders-size           <int> (Default 2)
    \\  -tags-margins                <int> (Default 5)
    \\  -tags-bg-color               <hex> 0xRRGGBB or 0xRRGGBBAA
    \\  -tags-fg-color               <hex> 0xRRGGBB or 0xRRGGBBAA
    \\  -tags-borders-color          <hex> 0xRRGGBB or 0xRRGGBBAA
    \\  -tags-focused-bg-color       <hex> 0xRRGGBB or 0xRRGGBBAA
    \\  -tags-focused-fg-color       <hex> 0xRRGGBB or 0xRRGGBBAA
    \\  -tags-focused-borders-color  <hex> 0xRRGGBB or 0xRRGGBBAA
    \\  -tags-occupied-bg-color      <hex> 0xRRGGBB or 0xRRGGBBAA
    \\  -tags-occupied-fg-color      <hex> 0xRRGGBB or 0xRRGGBBAA
    \\  -tags-occupied-borders-color <hex> 0xRRGGBB or 0xRRGGBBAA
    \\  -tags-urgent-bg-color        <hex> 0xRRGGBB or 0xRRGGBBAA
    \\  -tags-urgent-fg-color        <hex> 0xRRGGBB or 0xRRGGBBAA
    \\  -tags-urgent-borders-color   <hex> 0xRRGGBB or 0xRRGGBBAA
    \\
;

// Surface
surface_borders_size: u16 = 0,

surface_background_color: []const u8 = "0x202325",
surface_borders_color: []const u8 = "0x9e2f59",

// Layer surface
// <top>:<right>:<bottom>:<left>
layer_anchors: []const u8 = "0:1:1:0",
layer_margins: []const u8 = "0:10:10:0",

// Tags
tags_amount: u32 = 9,
tags_square_size: u16 = 50,
tags_borders_size: u16 = 2,
tags_margins: u16 = 5,
tags_number_text: bool = true,

tags_background_color: []const u8 = "0x3a4043",
tags_foreground_color: []const u8 = "0xdce1e4",
tags_border_colors: []const u8 = "0x646e73",

tags_focused_background_color: []const u8 = "0xf9f9fa",
tags_focused_foreground_color: []const u8 = "0x202325",
tags_focused_borders_color: []const u8 = "0xdce1e4",

tags_occupied_background_color: []const u8 = "0x2e3f9f",
tags_occupied_foreground_color: []const u8 = "0xdce1e4",
tags_occupied_borders_color: []const u8 = "0xdbf1fd",

tags_urgent_background_color: []const u8 = "0x9e2f59",
tags_urgent_foreground_color: []const u8 = "0x202325",
tags_urgent_borders_color: []const u8 = "0xfde7f6",

pub fn init(config: *Config) !void {
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
        config.surface_background_color = raw;
    }
    if (result.argFlag("-surface-borders-color")) |raw| {
        config.surface_borders_color = raw;
    }
    if (result.argFlag("-surface-borders-size")) |raw| {
        config.surface_borders_size = std.fmt.parseUnsigned(u16, raw, 10) catch
            fatalPrintUsage("invalid value '{s}' provided to -surface-borders-size", .{raw});
    }
    if (result.argFlag("-set-anchors")) |raw| {
        config.layer_anchors = raw;
    }
    if (result.argFlag("-set-margins")) |raw| {
        config.layer_margins = raw;
    }
    if (result.boolFlag("-no-tags-text")) {
        config.tags_number_text = false;
    }
    if (result.argFlag("-tags-amount")) |raw| {
        config.tags_amount = std.fmt.parseUnsigned(u32, raw, 10) catch
            fatalPrintUsage("invalid value '{s}' provided to -tags-amount", .{raw});
    }
    if (result.argFlag("-tags-square-size")) |raw| {
        config.tags_square_size = std.fmt.parseUnsigned(u16, raw, 10) catch
            fatalPrintUsage("invalid value '{s}' provided to -tags-square-size", .{raw});
    }
    if (result.argFlag("-tags-borders-size")) |raw| {
        config.tags_borders_size = std.fmt.parseUnsigned(u16, raw, 10) catch
            fatalPrintUsage("invalid value '{s}' provided to -tags-borders-size", .{raw});
    }
    if (result.argFlag("-tags-margins")) |raw| {
        config.surface_borders_size = std.fmt.parseUnsigned(u16, raw, 10) catch
            fatalPrintUsage("invalid value '{s}' provided to -tags-margins", .{raw});
    }
    if (result.argFlag("-tags-bg-color")) |raw| {
        config.tags_background_color = raw;
    }
    if (result.argFlag("-tags-fg-color")) |raw| {
        config.tags_foreground_color = raw;
    }
    if (result.argFlag("-tags-borders-color")) |raw| {
        config.tags_border_colors = raw;
    }
    if (result.argFlag("-tags-focused-bg-color")) |raw| {
        config.tags_focused_background_color = raw;
    }
    if (result.argFlag("-tags-focused-fg-color")) |raw| {
        config.tags_focused_foreground_color = raw;
    }
    if (result.argFlag("-tags-focused-borders-color")) |raw| {
        config.tags_focused_borders_color = raw;
    }
    if (result.argFlag("-tags-occupied-bg-color")) |raw| {
        config.tags_occupied_background_color = raw;
    }
    if (result.argFlag("-tags-occupied-fg-color")) |raw| {
        config.tags_occupied_foreground_color = raw;
    }
    if (result.argFlag("-tags-occupied-borders-color")) |raw| {
        config.tags_occupied_borders_color = raw;
    }
    if (result.argFlag("-tags-urgent-bg-color")) |raw| {
        config.tags_urgent_background_color = raw;
    }
    if (result.argFlag("-tags-urgent-fg-color")) |raw| {
        config.tags_urgent_foreground_color = raw;
    }
    if (result.argFlag("-tags-urgent-borders-color")) |raw| {
        config.tags_urgent_borders_color = raw;
    }
}

fn fatalPrintUsage(comptime format: []const u8, args: anytype) noreturn {
    log.err(format, args);
    std.io.getStdErr().writeAll(usage) catch {};
    os.exit(1);
}
