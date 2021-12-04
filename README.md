# Status

[WIP]

Not yet ready to daily use, and expect a lot of rebase and force push
in this repo at the beginning, sorry for the inconvenience.

This is currently mainly a learning project, with no end-goal
yet, first objective is to have more or less a zig port of
https://git.sr.ht/~leon_plickat/river-tag-overlay . And having a good base
for reusing files easily when you want to make a Wayland zig project.

Feel free to contribute.

TODO:

-   Fix the timeout working randomly.
-   Memory leaks. Some `invalid read of size` in `timespecDiff()`
    and in `Buffer.Create()`
-   Improve idiomatic zig. The point is to easily reuse some files in
    other Wayland projects, so the base should be clean.
-   Command line configuration at first and then maybe using a file.

# Building

Requirements:

-   river
-   zig 0.8.1
-   fcft 2.5.0

Init submodules:

    git submodule update --init

Build, `e.g.`

    zig build --prefix ~/.local

# License

[GNU General Public License v3.0 or later][]

[gnu general public license v3.0 or later]: COPYING
