// @xfail(raiser): raiser runtime error: expected an object, got value kind Int
// @stdout: named-fn storage ok
//
// A named function stored anywhere a function value lives — inside a
// `fn | null` or `fn | string` carrier, or through a storage type inferred
// from the function (object field, array element, return, generic binding,
// ternary, reassigned local) — is the closure pair on C and the bare
// function on JS, and calls the same on both.

function dbl(x: number): number { return x * 2; }
function tri(x: number): number { return x * 3; }
function id<T>(x: T): T { return x; }

function pickRet(flag: boolean) {
	if (flag) { return dbl; }
	return tri;
}

function maybeFn(flag: boolean): ((x: number) => number) | null {
	if (flag) { return tri; }
	return null;
}

function callMaybe(f: ((x: number) => number) | null): number {
	if (f === null) { return -1; }
	return f(1);
}

type Mount = { children: ((x: number) => number) | null };

function main(): void {
	const flag = callMaybe(dbl) > 0;
	const nullable: ((x: number) => number) | null = dbl;
	const either: ((x: number) => number) | string = tri;
	let viaUnion: number = -1;
	if (typeof either === "function") viaUnion = either(1);
	const m: Mount = { children: dbl };
	const o = { f: tri };
	const arr = [dbl, tri];
	const g = id(dbl);
	const t = flag ? tri : dbl;
	let f = dbl;
	f = tri;
	const got: number[] = [
		callMaybe(nullable), viaUnion, callMaybe(m.children), o.f(1), arr[0](1), arr[1](1),
		g(1), t(1), f(1), pickRet(true)(1), pickRet(false)(1), callMaybe(maybeFn(true)), callMaybe(maybeFn(false)),
	];
	let line = "";
	for (const v of got) line = line + v.toString() + " ";
	if (line == "2 3 2 3 2 3 2 3 3 2 3 3 -1 ") {
		console.log("named-fn storage ok");
	} else {
		console.log("named-fn storage BAD: " + line);
	}
}

main();
