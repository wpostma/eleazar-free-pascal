Eleazar
=======

**Eleazar** is a friendly fork of [Lazarus](https://www.lazarus-ide.org/), the
Rapid Application Development Tool for Free Pascal. The name comes from the
Hebrew original (אלעזר) that "Lazarus" derives from — meaning "God has helped."

This fork is fully open source under the same license as Lazarus. Any fixes or
improvements that the upstream Lazarus project finds useful are welcome to be
merged back. The goal is to move fast, build new experiences, and ship a polished,
regularly updated, stable IDE while contributing improvements upstream wherever possible.


### Eleazar Mission Statement

Eleazar is a friendly, forward‑looking fork of the Lazarus IDE, created to modernize the FreePascal development experience while strengthening the ecosystem that made it possible.We believe that innovation and stability are not opposites — they are partners — and that open‑source tools thrive when experimentation is encouraged, contributions are welcomed, and improvements flow freely upstream.

Eleazar exists to explore what Lazarus could be:

a cleaner, more consistent LCL (even at the cost of slight breaks in backwards compatibility) which we'll call the ECL, but it aims to be basically the LCL, but better.

a modern, flexible docking system (with fewer glitches and crashes)

a refreshed and intuitive IDE (not just refreshed art assets, but also 2x/4x icon sizes, and things like that)

a contributor‑friendly environment where new ideas can be accepted and tried (on their own branches, and then into trunk, after community feedback, kind of PRs done backwards) 

We are committed to transparency, open licensing, and collaboration. Wherever possible, Eleazar contributes fixes, refinements, and architectural improvements back to Lazarus, helping the core project evolve without compromising its stability.

Eleazar is not a replacement for Lazarus — it is a companion project, an R&D branch, and a catalyst for progress.Our goal is to empower developers, welcome new contributors, and push the Pascal ecosystem forward with respect, clarity, and ambition. We also plan to use a lot of the great stuff already there in FreePascal 3.x that isn't getting much of a workout yet in the classic LCL.

### Key Design Documents

- **[DOCKING_DESIGN.md](DOCKING_DESIGN.md)** — Architectural rules for the docking system to prevent feedback loops and maintain stability

---

Welcome to Lazarus
==================

Lazarus is a Rapid Application Development Tool for Free Pascal.
It comes with the LCL - Lazarus component library, which contains platform
independent visual components like buttons, windows, checkbox, treeview and
many, many more. The LCL is platform independent, so you can write an
application once and then compile for various platforms without changing code.

[Free Pascal](https://www.freepascal.org) is a fast Object Pascal compiler,
that runs on more than 20 platforms (Linux, Windows, BSD, OS/2, DOS, PowerPC,
and many more).

The LCL currently supports:
* Linux/FreeBSD (GTK2, Qt4, Qt5 and Qt6)
* all flavors of Windows (even WinCE)
* macOS (Cocoa, Carbon, GTK2, Qt4, Qt5, Qt6)

There is an experimental support for:
* GTK3
* Solaris 

The LCL still contains code for GTK1, although this target is obsolete.

### Compilation

You don't need ```./configure```, just do  
```make clean bigide``` (```gmake clean bigide``` in BSD).

This will create the Lazarus executable with a lot of packages.
Start it and enjoy.

If the above gives an error, you can try to build a minimal IDE with  
```make clean all``` (```gmake clean all``` in BSD).

### Installation and Requirements

See [Lazarus Wiki](https://wiki.freepascal.org/Category:Install) for details.

### Usage

Start the IDE with:
```shell
cd your/lazarus/directory
./lazarus
```

### Documentation

The official site is www.lazarus-ide.org.
Documents about specific topics can be found at 
https://wiki.freepascal.org/Lazarus_Documentation.
Examples on how to use the LCL can be found in the [examples](examples) directory.
Help, documents and files about Free Pascal are at www.freepascal.org.

### Mailing list

There is a very active and helpful mailing list for Lazarus, where the
developers interact, share ideas, discuss problems, and of course answer
questions.
You can subscribe at
http://lists.lazarus.freepascal.org/mailman/listinfo/lazarus.

### How to help Lazarus

If you find bugs, don't hesitate to use issue tracker,
or send an email to the list.
Lazarus source code and issue tracker are located at [GitLab](https://gitlab.com/freepascal.org/lazarus/lazarus).
