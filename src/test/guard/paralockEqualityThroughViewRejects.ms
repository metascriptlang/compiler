// nim-guard: an equality declared over the mutable type is refused through a read-only view.
//
// INVARIANT (PARALOCK E24): a view never converts back to the mutable type, so
//   `==` or `!=` written over `Readonly<Line>` cannot call `==`(a: Line, b: Line),
//   exactly as a method with a mutable receiver is refused through the view.
//
// WHAT IT CATCHES: the pre-fix compiler skipped the declared `==` without a word and
//   compared the views field by field, so a Map keyed by Line counted two keys the
//   author's `==` calls equal on C while JS called the author's `==` and counted one.
//
// RED MEANS: an equality through a view silently fell back to field-wise comparison.
//
// GUARD-CHECK-FAIL cannot call '==' on Readonly<Line> — a read-only view
// GUARD-CHECK-FAIL cannot call '!=' on Readonly<Line> — a read-only view

struct Line { text: string; runs: Vec<int32>; }
export function hash(this l: Readonly<Line>): int64 { return l.text.length as int64; }
function `==`(a: Line, b: Line): boolean { return a.text == b.text; }
function `!=`(a: Line, b: Line): boolean { return a.text != b.text; }

function same(a: Readonly<Line>, b: Readonly<Line>): boolean { return a == b; } // GUARD-REFUSED
function differ(a: Readonly<Line>, b: Line): boolean { return a != b; } // GUARD-REFUSED

const a: Line = { text: "a", runs: [] };
const m = new Map<Line, int32>();
m.set(a, 1); // GUARD-REFUSED
m.set({ text: "a", runs: [3] }, 2);
console.log(`${m.size} ${same(a, a)} ${differ(a, { text: "b", runs: [] })}`);
