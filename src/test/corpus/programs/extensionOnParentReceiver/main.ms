// @stdout: child true
// @stdout: grandchild true 5
// @stdout: generic 7 true true
// @stdout: first-of-two-parents 1
// @stdout: own-field own own
// note: an extension declared for an interface is found as a method on a value whose interface extends it, through every level, as the free call already finds it, and a generic parent binds its type argument from the child on both call forms; a function field of the value's own type still wins over a same-named extension.
import { Event, stopPropagation } from "./event";

interface PointerEvent extends Event { distance: float32; }
interface HitEvent extends PointerEvent { hit: int32; }

function twiceDistance(this e: PointerEvent): float32 { return e.distance * 2; }

interface Slot<T> { value: T; set: boolean; }
interface NamedSlot<T> extends Slot<T> { name: string; }

function mark<T>(this s: Slot<T>): void { s.set = true; }
function peek(this s: Slot<int32>): int32 { return s.value; }

interface Left { a: int32; }
interface Right { b: int32; }
interface Both extends Left, Right { c: int32; }

function leftOf(this x: Left): int32 { return x.a; }

interface Base { stopped: boolean; }
interface Owner extends Base { label: () => string; }
interface Labelled { label: () => string; }

function label(this b: Base): string { return "base"; }
function label(this l: Labelled): string { return "ext"; }

const p: PointerEvent = { type: "down", stopped: false, distance: 1.5 };
p.stopPropagation();
console.log(`child ${p.stopped}`);

const h: HitEvent = { type: "down", stopped: false, distance: 2.5, hit: 3 };
h.stopPropagation();
console.log(`grandchild ${h.stopped} ${h.twiceDistance()}`);

const n: NamedSlot<int32> = { value: 7, set: false, name: "n" };
n.mark();
const free: NamedSlot<int32> = { value: 7, set: false, name: "free" };
mark(free);
console.log(`generic ${n.peek()} ${n.set} ${free.set}`);

const both: Both = { a: 1, b: 2, c: 3 };
console.log(`first-of-two-parents ${both.leftOf()}`);

const o: Owner = { stopped: false, label: () => "own" };
const l: Labelled = { label: () => "own" };
console.log(`own-field ${o.label()} ${l.label()}`);
