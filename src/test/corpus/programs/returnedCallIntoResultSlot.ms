// @stdout: direct=n3:4 chained=n5:6 closure=c7:8 overload=s:9 generic=g11:12 self=n3n3:8 caught=n1:2,big 5 loop=n9:10
// note: a returned call whose struct result is the function's own result type is written by the callee straight into the caller's result slot, through a direct, chained, closure, overloaded and generic call, a callee that throws, and a value passed back into its own call. Same output on every lane.
struct Big { name: string; a: int64; b: int64; }

function core(n: int64): Big {
	return { name: "n" + n.toString(), a: n, b: n + 1 };
}
function forward(n: int64): Big { return core(n); }
function chained(n: int64): Big { return forward(n); }
function viaClosure(make: (n: int64) => Big, n: int64): Big { return make(n); }
function pick(n: int64): Big { return { name: "c" + n.toString(), a: n, b: n + 1 }; }
function pick(s: string): Big { return { name: s, a: 8, b: 9 }; }
function overloaded(s: string): Big { return pick(s); }
function boxed<T>(v: T, n: int64): Big { return { name: "g" + n.toString(), a: n, b: n + 1 }; }
function generic<T>(v: T, n: int64): Big { return boxed(v, n); }
function doubled(x: Big): Big { return { name: x.name + x.name, a: x.a + x.b, b: x.b * 2 }; }
function again(x: Big): Big { return doubled(x); }
function risky(n: int64): Big {
	if (n > 2) { throw new Error("big " + n.toString()); }
	return { name: "n" + n.toString(), a: n, b: n + 1 };
}
function forwardRisky(n: int64): Big { return risky(n); }
function guarded(n: int64): string {
	try {
		const v = forwardRisky(n);
		return v.name + ":" + v.b.toString();
	} catch (e) {
		return e.message;
	}
}
function show(v: Big): string { return v.name + ":" + v.b.toString(); }

function main(): void {
	const d = forward(3);
	const c = chained(5);
	const k = viaClosure((n: int64): Big => pick(n), 7);
	const o = overloaded("s");
	const g = generic<boolean>(true, 11);
	let s = forward(3);
	s = again(s);
	let last = forward(0);
	for (let i: int64 = 0; i < 10; i++) { last = chained(i); }
	console.log(`direct=${show(d)} chained=${show(c)} closure=${show(k)} overload=${o.name}:${o.b} generic=${show(g)} self=${s.name}:${s.b} caught=${guarded(1)},${guarded(5)} loop=${show(last)}`);
}
main();
