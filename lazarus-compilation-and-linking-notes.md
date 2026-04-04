# Lazarus Compilation and Linking Notes

## The short answer

Lazarus packages are **statically linked** into a single binary. There are no `.so`
files loaded at IDE startup for built-in components. The "package" concept is
primarily a source-level organizational unit, not a runtime loadable module.

## Build targets

```
make ide       # lean IDE, fewer packages compiled in
make bigide    # fat IDE, many extra packages including anchordockingdsgn
```

When `make bigide` runs, the build system:
1. Compiles each package's units to `.ppu`/`.o` files
2. Compiles the IDE itself, with all those package units in the search path
3. Links everything into one `lazarus` binary

The `ide` target skips many packages. Units from skipped packages are not in the
search path, so any IDE source file that `uses` them will fail to compile with
"unit not found".

## What a .lpk file describes

A `.lpk` (Lazarus Package) file declares:
- Which `.pas` units belong to the package
- What other packages it depends on
- Whether it should be compiled into the IDE binary

It is a build-time artifact. At runtime the binary has no knowledge of package
boundaries — it is one flat executable.

## Relevant example: anchordocking

`components/anchordocking/design/anchordockingdsgn.lpk` contains units like
`AnchorDesktopOptions`, `RegisterAnchorDocking`, etc. These are only compiled
when building `bigide`. If any IDE unit (e.g. `initialsetupproc.pas`) adds one
of these to its `uses` clause, it creates a hard compile-time dependency that
breaks the `ide` target.

## What CAN load dynamically (user packages)

User-installed packages (via `Package → Install/Uninstall packages`) do NOT load
at runtime as shared libraries. Instead, Lazarus **rebuilds itself**: it adds the
package's units to the IDE source list, recompiles, and relinks into a new binary.
Still static — just a new binary.

There is a `TIDEPackage`/`LoadPackage` mechanism for true runtime plugins, but it
is not used for core components like anchordocking.

## Summary table

| Mechanism              | anchordocking  | User packages       |
|------------------------|----------------|---------------------|
| Compiled in at build   | Yes (bigide)   | After IDE rebuild   |
| Loaded from .so at runtime | No         | No                  |
| Needs search path at compile time | Yes | Yes               |
