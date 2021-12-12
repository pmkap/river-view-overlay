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

// Surface
surface_borders_size: u16 = 0,

surface_color_background: []const u8 = "0x202325",
surface_color_borders: []const u8 = "0x9e2f59",

// Layer surface
// <top>:<right>:<bottom>:<left>
layer_anchors: []const u8 = "1:1:0:0",
layer_margins: []const u8 = "10:10:0:0",

// Tags
tags_amount: u32 = 9,
tags_square_size: u16 = 50,
tags_borders_size: u16 = 2,
tags_margins: u16 = 5,
tags_number_text: bool = true,

tags_color_background: []const u8 = "0x3a4043",
tags_color_borders: []const u8 = "0x646e73",

tags_color_focused: []const u8 = "0xf9f9fa",
tags_color_borders_focused: []const u8 = "0xdce1e4",

tags_color_occupied: []const u8 = "0x2e3f9f",
tags_color_borders_occupied: []const u8 = "0xdbf1fd",

tags_color_urgent: []const u8 = "0x9e2f59",
tags_color_borders_urgent: []const u8 = "0xfde7f6",

tags_color_foreground: []const u8 = "0xdce1e4",
tags_color_foreground_focused: []const u8 = "0x202325",
tags_color_foreground_occupied: []const u8 = "0xdce1e4",
tags_color_foreground_urgent: []const u8 = "0x202325",
