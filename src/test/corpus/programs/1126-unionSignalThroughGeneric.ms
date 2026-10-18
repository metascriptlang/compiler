// @xfail(raiser): raiser runtime error: cannot evaluate typeof at comptime: a function variant shares its Raiser value kind with a number or object variant (inbox 2026-10-15-raiser-typeof-cannot-tell-a-function-from-an-object)
// @stdout: mode=handled,never,always
// @stdout: inline=off,on
// @stdout: cell=1,two,3
// @stdout: shape=circle:2,square:5

type Setter<T> = (v: T | ((prev: T) => T)) => void;

function createSignal<T>(initial: T): [() => T, Setter<T>] {
	let cur = initial;
	return [
		() => cur,
		(v: T | ((prev: T) => T)) => {
			if (typeof v === "function") { cur = v(cur); } else { cur = v; }
		},
	];
}

type Mode = "never" | "always" | "handled";
const [mode, setMode] = createSignal<Mode>("never");
setMode("handled");
const m1 = mode();
setMode((prev: Mode): Mode => prev == "handled" ? "never" : "always");
const m2 = mode();
setMode((prev: Mode): Mode => prev == "never" ? "always" : "handled");
console.log("mode=" + m1 + "," + m2 + "," + mode());

const start = "off" as "on" | "off";
const [power, setPower] = createSignal(start);
const p1 = power();
setPower("on");
console.log("inline=" + p1 + "," + power());

const [cell, setCell] = createSignal<number | string>(1);
const c1 = cell();
setCell("two");
const c2 = cell();
setCell((prev: number | string): number | string => typeof prev === "string" ? prev.length : prev);
console.log("cell=" + c1.toString() + "," + c2.toString() + "," + cell().toString());

type Shape = { kind: "circle"; r: number } | { kind: "square"; side: number };
const [shape, setShape] = createSignal<Shape>({ kind: "circle", r: 2 });
const area = (s: Shape): string => s.kind == "circle" ? "circle:" + s.r.toString() : "square:" + s.side.toString();
const s1 = area(shape());
setShape({ kind: "square", side: 5 });
console.log("shape=" + s1 + "," + area(shape()));
