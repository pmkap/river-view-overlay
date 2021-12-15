# Agertu

## Status

This project should now works as expected, although it far from perfect.

This is currently mainly a learning project, with no end-goal, first objective
is to have more or less a zig port of [river-tag-overlay] . And having a
good base for reusing files easily when you want to make a Wayland zig project.

Contribution welcome!

### TODO

-   Improve performance
-   Improve abstraction. The point is to easily reuse some files in other
    Wayland projects, so the base should be clean.
-   Improve command line configuration, maybe rewrite a parser, and then
    maybe use a file.
-   Improve idiomatic zig if needed

## Building

Requirements:

-   [river]
-   [zig] 0.8.1
-   [fcft] 2.5.0

Init submodules:

    git submodule update --init

Build, `e.g.`

    zig build --prefix ~/.local

## Contributing

For patches, questions or discussion send a [plain text] mail to my
[public inbox] [~novakane/public-inbox@lists.sr.ht] with project
prefix set to `agertu`:

```bash
git config sendemail.to "~novakane/public-inbox@lists.sr.ht"
git config format.subjectPrefix "PATCH agertu"
```

See [here] for some great resource on how to use `git send-email`
if you're not used to it, and my [wiki].

## License

[GNU General Public License v3.0 or later]

[river-tag-overlay]: https://git.sr.ht/~leon_plickat/river-tag-overlay
[river]: https://github.com/riverwm/river
[fcft]: https://codeberg.org/dnkl/fcft
[zig]: https://ziglang.org/download/
[plain text]: https://useplaintext.email/
[public inbox]: https://lists.sr.ht/~novakane/public-inbox
[~novakane/public-inbox@lists.sr.ht]: mailto:~novakane/public-inbox@lists.sr.ht
[here]: https://git-send-email.io
[wiki]: https://man.sr.ht/~novakane/guides/
[gnu general public license v3.0 or later]: COPYING
