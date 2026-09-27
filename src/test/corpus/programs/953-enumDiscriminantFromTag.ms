// @stdout: A B true true|A3 Byy 5 10|cab 2
// note: an enum discriminant is read from the union tag through each variant's enum member: TS-style variants out of enum order, a match type over an enum with explicit values, and match arms out of enum order (C read the variant index as the enum value).

enum K { A, B }
interface Bv { kind: K.B; y: int32 }
struct Av { kind: K.A; x: int32 }
type E = Bv | Av;

enum S { A = 5, B = 10 }
type D = match (kind: S) { S.A => { x: int32 }, S.B => { y: string } };

enum K3 { A, B, C }
type D3 = match (kind: K3) { K3.C => { z: int32 }, K3.A => { x: int32 }, K3.B => { y: string } };

function nameE(e: E): string {
	if (e.kind === K.A) return "A";
	return "B";
}

function showD(d: D): string {
	if (d.kind == S.A) return "A" + d.x.toString();
	if (d.kind == S.B) return "B" + d.y;
	return "none";
}

function showD3(d: D3): string {
	return match (d.kind) { K3.A => "a", K3.B => "b", K3.C => "c" };
}

function mkD(b: boolean): D { return b ? { kind: S.B, y: "yy" } : { kind: S.A, x: 3 }; }

function run(): string {
	const lines: string[] = [];
	const a: E = { kind: K.A, x: 1 } as Av;
	const b: E = { kind: K.B, y: 2 } as Bv;
	lines.push(`${nameE(a)} ${nameE(b)} ${a.kind == K.A} ${b.kind == K.B}`);
	const da = mkD(false);
	const db = mkD(true);
	lines.push(`${showD(da)} ${showD(db)} ${(da.kind as int32).toString()} ${(db.kind as int32).toString()}`);
	const c: D3 = { kind: K3.C, z: 9 };
	const x: D3 = { kind: K3.A, x: 1 };
	const y: D3 = { kind: K3.B, y: "q" };
	lines.push(`${showD3(c) + showD3(x) + showD3(y)} ${(c.kind as int32).toString()}`);
	return lines.join("|");
}
console.log(run());
