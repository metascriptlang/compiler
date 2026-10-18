export enum K { A, B }
export struct S = match (kind: K) { K.A => { r: string }, K.B => { n: int32 } };
export struct P = match (ok: boolean) { true => { value: string }, false => { error: string } };
export function mkS(a: boolean): S { return a ? { kind: K.A, r: "ra" } : { kind: K.B, n: 7 }; }
export function mkP(a: boolean): P { return a ? { ok: true, value: "pv" } : { ok: false, error: "pe" }; }
export function readS(s: S): string { if (s.kind === K.A) return s.r; return `${s.n}`; }
export function readP(p: P): string { if (p.ok) return p.value; return p.error; }
export function sizes(): string { return `${sizeof(S)} ${sizeof(P)} ${sizeof(Result<int32, string>)}`; }
export function okR(): Result<int32, string> { return Result.ok(5); }
export function fromObject(o: { ok: false; error: string }): P { return o; }
