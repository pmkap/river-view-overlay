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
const pixman = @import("pixman");

/// Render a rectangle with a colored background and colored borders
/// inside the rectangle.
pub fn renderBorderedRectangle(
    image: *pixman.Image,
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    borders_size: u16,
    background_color: *const pixman.Color,
    borders_color: *const pixman.Color,
) !void {
    // Render background
    const background = [1]pixman.Rectangle16{
        .{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
        },
    };
    _ = pixman.Image.fillRectangles(
        .src,
        image,
        background_color,
        1,
        &background,
    );

    // Render borders
    const borders = [4]pixman.Rectangle16{
        // Top
        .{
            .x = x,
            .y = y,
            .width = width,
            .height = borders_size,
        },
        // Bottom
        .{
            .x = x,
            .y = y + @intCast(i16, height - borders_size),
            .width = width,
            .height = borders_size,
        },
        // Left
        .{
            .x = x,
            .y = y + @intCast(i16, borders_size),
            .width = borders_size,
            .height = height - 2 * borders_size,
        },
        // Right
        .{
            .x = x + @intCast(i16, width - borders_size),
            .y = y + @intCast(i16, borders_size),
            .width = borders_size,
            .height = height - 2 * borders_size,
        },
    };
    _ = pixman.Image.fillRectangles(
        .src,
        image,
        borders_color,
        4,
        &borders,
    );
}

/// Render a given text.
/// 'x_start' and 'y_start' are the starting point of the text.
/// 'y_start' is the baseline so glyphs will be rendered above 'y_start'.
pub fn renderBytes(
    image: *pixman.Image,
    bytes: []const u8,
    font: *fcft.Font,
    foreground: *const pixman.Color,
    surface_borders_size: u32,
    x_start: i32,
    y_start: i32,
) !void {
    const color = pixman.Image.createSolidFill(foreground).?;
    defer _ = color.unref();

    // Pen position in the surface.
    const Pen = struct { x: i32, y: i32 };
    var pen: Pen = .{
        .x = x_start,
        .y = y_start,
    };

    for (bytes) |char| {
        // The glyph object is managed by fcft.Font and freed
        // when fcft.destroy() is called.
        var glyph = try fcft.Glyph.rasterize(font, char, .default);

        var x_kern: c_long = 0;
        _ = fcft.kerning(font, char - 1, char, &x_kern, null);

        pen.x += @intCast(u8, x_kern);

        switch (pixman.Image.getFormat(glyph.pix)) {
            // Glyph is a pre-rendered image. (e.g. a color emoji)
            .a8r8g8b8 => {
                pixman.Image.composite32(
                    .over,
                    glyph.pix,
                    null,
                    image,
                    0,
                    0,
                    0,
                    0,
                    pen.x + @intCast(i32, glyph.x),
                    pen.y + @intCast(i32, font.ascent - glyph.y),
                    glyph.width,
                    glyph.height,
                );
            },
            // Glyph is an alpha mask.
            else => {
                pixman.Image.composite32(
                    .over,
                    color,
                    glyph.pix,
                    image,
                    0,
                    0,
                    0,
                    0,
                    pen.x + @intCast(i32, glyph.x),
                    pen.y + @intCast(i32, font.ascent - glyph.y),
                    glyph.width,
                    glyph.height,
                );
            },
        }

        // Advance pen position.
        pen.x += @intCast(u8, glyph.advance.x);
    }
}
