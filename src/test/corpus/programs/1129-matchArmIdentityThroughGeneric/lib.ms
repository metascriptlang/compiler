export enum K { P, Q }
export struct S = match (kind: K) {
	K.P => { x: number },
	K.Q => { y: string },
};
export struct G<T> = match (kind: K) {
	K.P => { x: T },
	K.Q => { y: string },
};
export function hold<T>(v: T): T[] { return [v, v]; }
export function libS(): string {
	const s: S = { kind: K.P, x: 41 };
	if (s.kind == K.P) { const xs = hold(s); return `lib-s ${xs[1].x + 1}`; }
	return "lib-s none";
}
export function libG(): string {
	const g: G<number> = { kind: K.P, x: 5 };
	if (g.kind == K.P) { const xs = hold(g); return `lib-g ${xs[1].x * 2}`; }
	return "lib-g none";
}
