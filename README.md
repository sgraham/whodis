Whodis?
-------

Compilation disassembly viewer for Vim.

To use it:

    git clone https://github.com/sgraham/whodis.git ~/.vim/whodis

And add:

    set runtimepath^=~/.vim/whodis

to your .vimrc.

You need to generate a compilation database into compile_commands.json at the
root of your source tree. If you build with ninja, you can do that with
something like:

    ninja -C out/Release -t compdb cc cxx > compile_commands.json

In Vim, push `Ctrl-Shift-A` to view disassembly for the current function. Toggle
it back off with `Ctrl-Shift-A` again, in either the disassembly view or the
original source file. On Mac, use `Cmd-Shift-A` instead. This mapping can be
overridden by setting `g:WhodisKey` in your .vimrc.

Line attribution is done by colour, so you can visually see which lines
correspond to which instructions. This works in GUI and xterm256.

A lot of directives and miscellaneous annotations are stripped out to try to
make the disassembly more readable, so if you're looking for something more than
just the instructions and control flow, prefer to inspect a raw .S directly. You
can also set `g:WhodisFilterProgram` in your .vimrc, for example to `c++filt` to
run additional custom filtering on the .S.

If there's no code associated with the line the cursor was on when you activate
whodis, it won't know what function you wanted. Jumping to the opening brace of
the function with `[m` can be useful in that case.

It's also sometimes interesting/useful to open up `compile_commands.json` and
fiddle with the command for the file that you're investigating, e.g. `-Os` vs.
`-O3`, or try different `-march=`.

![Demo](demo.gif)

Scott Graham scott.whodis@h4ck3r.net
