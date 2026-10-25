// @stdout: h4 1
// note: two generic classes that hold each other with an argument that grows on every level (`P<T>` holds `Q<T[]>`, `Q<T>` holds `P<T>`), reached through an alias and a generic function. Building each body meets a new, larger instance, so the checker stops expanding after a bounded number of builds and reuses the instance it made last at the same spot; before that bound, `msc check` and the C build never finished. Same output on every backend.
class P<T> { q: Q<T[]> | null = null; v: T; constructor(v: T) { this.v = v; } }
class Q<T> { p: P<T> | null = null; }
type PA<T> = P<T>;
function mk<U>(v: U): PA<U> { return new P(v); }
const p = mk(1);
p.q = new Q<int32[]>();
console.log("h4 " + String(p.v));
