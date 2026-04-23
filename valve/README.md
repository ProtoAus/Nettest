# ![](img/rt.png) Rad-Therapy

This is a clone of the 1998 game known as 'HL1', porting it to Quake(World) because it's the nearest neighbor.
Powered by Nuclide and the [FTE Engine](https://www.fteqw.org/).

![Preview 1](img/preview1.jpg)
![Preview 2](img/preview2.jpg)
![Preview 3](img/preview3.jpg)
![Preview 4](img/preview4.jpg)

## Installing/Running

To run it, all you need is [FTE](https://www.fteqw.org) and [the latest release .pk3 file](https://www.frag-net.com/pkgs/package_valve.pk3), which you save into `HL1/valve/`. 

**That's about it.**

You can install updates through the **Configuration > Updates** menu.

**To eager porters/packagers**: *Rad-Therapy is QuakeC - there is no native code.*
You only need to build this from source if you plan on making changes. The `package_valve.pk3` file is essentially 'data', you **don't need to compile it**. *If anything, you may fail multiplayer server purity checks.*
Ensure `fteqw` and the `fteplug_ffmpeg` plugin are ported. That's it.

**The engine has no idea what's going on, besides loading the file formats. Menus, client and server game and sub-protocol network activities are all handled by Rad-Therapy.**

## Building from Source

Clone the repository into the [Nuclide-SDK](https://code.idtech.space/vera/nuclide) and build it like so:

```
$ cd nuclide
$ git clone https://code.idtech.space/fn/valve valve
$ make game GAME=valve
```

## Notes

The engine should automatically detect HL1 when placed within the game directory, however you may need to pass `-halflife` just in case you have one massive directory with multiple FTE-supported games in it.

You can also launch mods like this: `fteqw -halflife -game cstrike`

## Goals/Non-Goals

- Rad-Therapy is not HL1 and is not intended to 'replace' HL1. 
- Be able to complete the game in singleplayer, and be aware of custom maps, mods and what they often like to do as well.
- It should also be compatible with whatever free or libre replacement data will become available in the future.
- It's not a port of existing sources, and is not compatible with mods unless they too are rebuilt.
- It meant to be used to build other games and projects, similar to what HL1 is.
- It's supposed to feel authentic to what HL1 was, but without the jank you don't care to remember.

## Community

### Matrix
If you're a fellow Matrix user, join the Nuclide Space to see live-updates and be able to ask technical questions regarding the project.
https://matrix.to/#/#nuclide:matrix.org

### IRC
Join us on #freecs via irc.libera.chat and talk/lurk or discuss bugs, issues
and other such things. It's bridged with the Matrix room of the same name!

### Others
We've had people ask in the oddest of places for help, please don't do that.

## Special Thanks

- Spike for FTEQW and for being the most helpful person all around!
- Xylemon for the hundreds of test maps, verifying entity and game-logic behaviour
- Theuaredead`, preston22, dqus for various patches
- To my supporters on Patreon, who are always eager to follow what I do.
- Any and all people trying it, tinkering with it etc. :)

## License

### Source Code

ISC License

Copyright (c) 2016-2025 Marco "eukara" Cawthorne <marco@icculus.org>

Permission to use, copy, modify, and distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF MIND, USE, DATA OR PROFITS, WHETHER
IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

### Branding, Logo

The **Rad-Therapy** name and the *Rad-Therapy Triskelion* logo were created and
donated to the project by [Vera Visions L.L.C.](https://www.vera-visions.com)
for everyone to use or enjoy under the [CC BY license](https://creativecommons.org/licenses/by/4.0/).
