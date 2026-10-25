// @stdout: lib-s 42|main-s b 7|lib-g 10|main-g q 3|one-module 6 z
// note: a `struct` match union's arm is its own type, declared by its union. Two modules
// declaring a same-named union, and one generic union instantiated twice, pass their arms
// through one generic function: each arm keeps its own instance, C struct and hooks, where
// the arm used to be identified by its spelling `S.P` and take the other module's layout.
import { hold, libG, libS } from "./lib";

enum K { R, P }
struct S = match (kind: K) {
	K.R => { z: boolean },
	K.P => { label: string, n: int32 },
};
struct G<T> = match (kind: K) {
	K.R => { y: string },
	K.P => { w: string, x: T },
};

function mainS(): string {
	const s: S = { kind: K.P, label: "b", n: 7 };
	if (s.kind == K.P) { const xs = hold(s); return `main-s ${xs[1].label} ${xs[1].n}`; }
	return "main-s none";
}

function mainG(): string {
	const g: G<int32> = { kind: K.P, w: "q", x: 3 };
	if (g.kind == K.P) { const xs = hold(g); return `main-g ${xs[0].w} ${xs[1].x}`; }
	return "main-g none";
}

function oneModule(): string {
	const a: G<number> = { kind: K.P, w: "a", x: 5 };
	const b: G<string> = { kind: K.P, w: "b", x: "z" };
	if (a.kind == K.P && b.kind == K.P) {
		const xs = hold(a);
		const ys = hold(b);
		return `one-module ${xs[1].x + 1} ${ys[1].x}`;
	}
	return "one-module none";
}

console.log([libS(), mainS(), libG(), mainG(), oneModule()].join("|"));
