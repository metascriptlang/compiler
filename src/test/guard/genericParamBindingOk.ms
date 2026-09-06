// nim-guard: the three legal ways a generic param gets bound stay accepted.
//
// INVARIANT: the unbound-param gate (genericUnboundParam.ms) must not reject
//   (a) contextual binding — the declared destination type binds the param at
//       the call (`const r: Result<S, string> = Result.ok(t)`),
//   (b) explicit type args (`ident<S>(t)`),
//   (c) a non-generic method of a generic class calling a function-typed
//       parameter (`Cell<T>.update(fn)`) — checked pre-monomorphization with
//       T legitimately open; the ctx.inGenericContext gate exists for exactly
//       this shape (real-world: signal update in the UI framework).
//
// WHAT IT CATCHES: widening the unbound-param check past its boundary —
//   ungated, it rejects every generic class whose method calls a fn-typed
//   param; over-eager, it rejects contextual/explicit binding.
//
// RED MEANS: the gate fires where a binding source exists; check the
//   inGenericContext inc/dec pairing in checkClassDecl first.
//
// GUARD-JS

struct GuardGbS { a: int32; b: string; }

function ident<T>(x: T): T { return x; }

class GuardCell<T> {
    value: T;
    constructor(v: T) { this.value = v; }
    get(): T { return this.value; }
    set(v: T): void { this.value = v; }
    update(fn: (current: T) => T): void { this.set(fn(this.value)); }
}

function main(): void {
    const t: GuardGbS = { a: 1, b: "x" };
    const r: Result<GuardGbS, string> = Result.ok(t);
    if (r.ok) { console.log("ctx=" + r.value.b); }
    const u: GuardGbS = ident<GuardGbS>(t);
    console.log("expl=" + u.b);
    const c = new GuardCell<int32>(5);
    c.update((x: int32) => x + 1);
    const s = new GuardCell<string>("a");
    s.update((x: string) => x + "b");
    if (c.get() == 6 && s.get() == "ab") {
        console.log("GUARD-OK");
    } else {
        console.log("GUARD-RED c=" + c.get() + " s=" + s.get());
        process.exit(1);
    }
}
main();
