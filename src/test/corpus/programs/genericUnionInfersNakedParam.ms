// @stdout: union-infer ok 6
// note: a parameter typed as a union of a generic instance and its naked type parameter infers `T` the way TS does: a `Promise<string>` binds `T = string` through `Promise<T>`, and a plain value binds the naked `T` itself, for `Promise<T> | T` and `T | ((prev: T) => T)`, with a number, a string, an object literal and an awaited async result. Same output on C, JS and the Raiser.
let wrong = "";
let rows = 0;
function row(name: string, got: string, want: string): void {
	rows += 1;
	if (got != want) wrong += " " + name + "=" + got + "(want " + want + ")";
}

function slot<T>(x: Promise<T> | T): T[] { return []; }
function updater<T>(x: T | ((prev: T) => T)): T[] { return []; }
async function later(): Promise<string> { return "x"; }

const nums: int32[] = slot(2);
const strs: string[] = slot("s");
const fromPromise: string[] = slot(later());
const objs = slot({ a: 1 });
const counts: int32[] = updater(3);
const fromFn: number[] = updater((prev: number): number => prev + 1);
row("number", nums.length.toString(), "0");
row("string", strs.length.toString(), "0");
row("promise", fromPromise.length.toString(), "0");
row("object", objs.length.toString(), "0");
row("updater value", counts.length.toString(), "0");
row("updater function", fromFn.length.toString(), "0");
console.log(wrong == "" ? "union-infer ok " + rows.toString() : "union-infer WRONG" + wrong);
