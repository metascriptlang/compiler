// nim-guard: one source file is ONE module, whatever spelling reaches it. A
// second identity for the same file duplicates its module state and its export
// table — the C lane then emits the file twice, and its `@compile` sources link
// twice as duplicate symbols.
//
// INVARIANT: module identity is the PHYSICAL path, and the export table shares
//   that key. Reference (read 2026-09-11): `fileInfoIdx` (msgs.nim:95) keys the
//   file table on `canonicalizePath` (options.nim:894 — `expandFilename`, which
//   resolves symlinks) plus `canonicalCase`; `ModuleGraph` then indexes both the
//   module and its export interface by that FileIndex (`getModule`,
//   modulegraphs.nim:812; `ifaces[fileIdx].interf`, modulegraphs.nim:1070).
//   One key, so resolving a spelling and looking up its exports cannot disagree.
//
// WHY MODULE STATE IS THE PROBE: a duplicated identity gives each copy its own
//   module-level `bumpCount`, so the second call restarts at 1 instead of
//   counting 2 — visible without reading emitted C.
//
// FIXTURE: `fixtures/moduleIdentity/link` is a git symlink to `lib` (mode
//   120000). A Windows checkout without symlink support materializes it as a
//   one-line text file (docs/WINDOWS-TRAPS.md) — that is a checkout artifact,
//   not drift, and this probe cannot speak there.
//
// RED PRE-FIX: bumpThroughSymlink() == 1 — `lib/dep.ms` and `link/dep.ms` are
//   two modules with two counters.
// RED HALF-FIX: build fails with "Module '../link/dep' has no export 'bump'" —
//   the graph key was canonicalized but the import entry kept its spelling.

import { bump } from "./fixtures/moduleIdentity/lib/dep";
import { bumpThroughSymlink } from "./fixtures/moduleIdentity/sub/viaLink";
import { exit } from "std/process";

const first = bump();
const second = bumpThroughSymlink();

console.log(`direct=${first} throughSymlink=${second}`);

if (first != 1) {
	console.log("GUARD-FAIL the direct import did not see a fresh module");
	exit(1);
}

if (second != 2) {
	console.log("GUARD-FAIL the symlinked spelling owns a second copy of the module");
	exit(1);
}

console.log("GUARD-OK");
