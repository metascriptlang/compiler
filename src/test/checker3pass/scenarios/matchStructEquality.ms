import { checkOnly } from "../helpers";

const HEAD = `
enum K { O, P }
struct CP = match (kind: K) {
	K.O => { w: float32, snap: boolean },
	K.P => { fovY: float32 },
};
const a: CP = { kind: K.P, fovY: 1.0 };
const c: CP = { kind: K.O, w: 0.1, snap: false };
`;

const SRC_DIRECT = HEAD + `
struct R = match (ok: boolean) {
	true => { v: int32 },
	false => { e: string },
};
const r: R = { ok: true, v: 1 };
const eq = a == c;
const ne = a != c;
const strict = a === c;
const strictNe = a !== c;
const boolArm = r === r;
`;

const SRC_HELD = HEAD + `
struct Cam { z: int32, p: CP }
struct Box<T> { v: T, n: int32 }
const cam: Cam = { z: 1, p: a };
const pair: [CP, int32] = [a, 1];
const box: Box<CP> = { v: a, n: 1 };
const fixed: CP[2] = [a, c];
const byField = cam == cam;
const byElement = pair != pair;
const byInstance = box === box;
const byFixed = fixed !== fixed;
`;

const SRC_GENERIC = HEAD + `
function same<T>(x: T, y: T): boolean { return x === y; }
const viaGeneric = same<CP>(a, c);
`;

const SRC_DECLARED = HEAD + `
export function \`==\`(this x: CP, y: CP): boolean {
	if (x.kind == K.P && y.kind == K.P) return x.fovY == y.fovY;
	if (x.kind == K.O && y.kind == K.O) return x.w == y.w && x.snap == y.snap;
	return false;
}
struct Cam { z: int32, p: CP }
function same<T>(x: T, y: T): boolean { return x === y; }
function differ<T>(x: T, y: T): boolean { return x !== y; }
const cam: Cam = { z: 1, p: a };
const all = [a == c, a != c, a === c, a !== c, cam == cam, cam != cam, same<CP>(a, c), differ<CP>(a, c)];
`;

const SRC_UNREFUSED = `
enum K { O, P }
type Ref = match (kind: K) {
	K.O => { w: float32 },
	K.P => { fovY: float32 },
};
struct V { x: int32 }
function pick(k: int32): Ref { if (k == 0) return { kind: K.O, w: 1.0 }; return { kind: K.P, fovY: 1.0 }; }
const byIdentity = pick(0) === pick(1);
const v: V = { x: 1 };
const byValue = v == v;
const ok: Result<int32, string> = Result.ok(1);
const byResult = ok == ok;
`;

const SRC_UNION = HEAD + `
struct CQ = match (kind: K) {
	K.O => { x: int32 },
	K.P => { y: int32 },
};
struct HoldI { c: CP | int32, n: int32 }
struct HoldU { c: CP | CQ, n: int32 }
const q: CQ = { kind: K.O, x: 1 };
const hi: HoldI = { c: a, n: 1 };
const hu: HoldU = { c: q, n: 1 };
const ui: CP | int32 = a;
const uu: CP | CQ = a;
const t: [CP | int32, int32] = [a, 1];
const all = [hi == hi, hu != hu, ui === ui, uu !== uu, t == t];
`;

function errorsOf(source: string): string {
	return checkOnly(source).errors.join("\n");
}

function refusal(op: string, shown: string, held: string): string {
	const holds = shown == held ? "" : "it holds '" + held + "', ";
	return "cannot compare '" + shown + "' with '" + op + "': " + holds + "a match struct has no built-in equality; declare `==`(this a: "
		+ held + ", b: " + held + "): boolean for it";
}

test "== != === !== on a match struct with no declared == are refused, naming the struct" {
	const text = errorsOf(SRC_DIRECT);
	assert text.contains(refusal("==", "CP", "CP")), "a == c must be refused: " + text;
	assert text.contains(refusal("!=", "CP", "CP")), "a != c must be refused: " + text;
	assert text.contains(refusal("===", "CP", "CP")), "a === c must be refused: " + text;
	assert text.contains(refusal("!==", "CP", "CP")), "a !== c must be refused: " + text;
	assert text.contains(refusal("===", "R", "R")), "a boolean-discriminated match struct must be refused: " + text;
}

test "a struct, tuple or fixed array whose equality reaches a match struct is refused where it is compared" {
	const text = errorsOf(SRC_HELD);
	assert text.contains(refusal("==", "Cam", "CP")), "a struct field must be reached: " + text;
	assert text.contains("' with '!=': it holds 'CP', a match struct"), "a tuple element must be reached: " + text;
	assert text.contains("' with '===': it holds 'CP', a match struct"), "a field of a generic struct instance must be reached: " + text;
	assert text.contains("' with '!==': it holds 'CP', a match struct"), "a fixed array element must be reached: " + text;
	assert text.split("it holds 'CP'").length == 5, "each of the four holders must be refused once: " + text;
}

test "a generic comparison instantiated with a match struct is refused" {
	const text = errorsOf(SRC_GENERIC);
	assert text.contains(refusal("===", "CP", "CP")), "same<CP> must be refused: " + text;
}

test "a match struct with a declared == compares through it, and != derives from it" {
	const result = checkOnly(SRC_DECLARED);
	assert result.errors.length == 0, "a declared == must check: " + result.errors.join("\n");
}

test "a reference match union, a plain struct and a Result keep their equality" {
	const result = checkOnly(SRC_UNREFUSED);
	assert result.errors.length == 0, "identity and value equality must check: " + result.errors.join("\n");
}

test "a union holding a match struct is not refused, as an operand or as a field or element" {
	const text = errorsOf(SRC_UNION);
	assert !text.contains("a match struct has no built-in equality"), "a union is not a match struct: " + text;
}
