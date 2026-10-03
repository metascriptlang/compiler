// @xfail(raiser): error: Cannot resolve module 'std/core/buffer'
// @stdout: {"name":"x","n":3,"c":"Blue","s":"Inactive","cs":["Green","Red"]}
// note: every lane shares the codec macros, so each check also grades itself into the exit code.
import { exit } from "std/process";
import { cborEncode, decode, cborValueToStruct, cborInt, _cborArrayOfEnums, _cborToEnumArray } from "std/serialize/cbor";

enum Kind832 { Click, Key }
interface Click832 { kind: Kind832.Click; x: int32; }
interface Key832 { kind: Kind832.Key; code: int32; }
type Ev832 = Click832 | Key832;

enum Color832 { Red, Green, Blue }
enum Status832 { Active = 5, Inactive = 2 }
interface Paint832 { name: string; n: int32; c: Color832; s: Status832; cs: Color832[]; }
interface Palette832 { name: string; cs: Color832[]; }

let failures: int32 = 0;

function check(label: string, ok: boolean): void {
	console.log(`${label} ${ok}`);
	if (!ok) failures += 1;
}

function jsonSide(): void {
	const e: Ev832 = { kind: Kind832.Click, x: 7 };
	const s = JSON.stringify(e);
	console.log(s);
	check("json discriminant by name", s == `{"kind":"Click","x":7}`);
	const k: Ev832 = { kind: Kind832.Key, code: 42 };
	const back = JSON.parse<Ev832>(JSON.stringify(k));
	check("json union round trip", back.ok && back.value.kind == Kind832.Key);
	const bad = JSON.parse<Ev832>(`{"kind":1,"code":42}`);
	check("json numeric discriminant rejected", !bad.ok && bad.error.includes("field 'kind': expected string, got int"));
	const p: Paint832 = { name: "x", n: 3, c: Color832.Blue, s: Status832.Inactive, cs: [Color832.Green, Color832.Red] };
	console.log(JSON.stringify(p));
	const pal = JSON.parse<Palette832>(`{"name":"y","cs":["Blue","Red","Green"]}`);
	check("json array by name", pal.ok && pal.value.cs.length == 3 && pal.value.cs[0] == Color832.Blue && pal.value.cs[2] == Color832.Green);
	const palBad = JSON.parse<Palette832>(`{"name":"y","cs":["Blue",2]}`);
	check("json numeric element rejected", !palBad.ok && palBad.error == "field 'cs[1]': expected Color832 member name, got int");
}

function cborSide(): void {
	const k: Ev832 = { kind: Kind832.Key, code: 42 };
	const rk = decode(cborEncode(k));
	check("cbor discriminant by name", rk.ok && rk.value.getDynamicField("kind").asString() == "Key");
	const back: Ev832 = cborValueToStruct(rk.ok ? rk.value : cborInt(0), null as Ev832 | null);
	check("cbor union round trip", back.kind == Kind832.Key);
	const p: Paint832 = { name: "x", n: 3, c: Color832.Blue, s: Status832.Inactive, cs: [Color832.Green, Color832.Red] };
	const rp = decode(cborEncode(p));
	check("cbor fields by name", rp.ok && rp.value.getDynamicField("c").asString() == "Blue"
		&& rp.value.getDynamicField("s").asString() == "Inactive"
		&& rp.value.getDynamicField("cs").at(1).asString() == "Red");
	const q: Paint832 = cborValueToStruct(rp.ok ? rp.value : cborInt(0), null as Paint832 | null);
	check("cbor struct round trip", q.name == "x" && q.n == 3 && q.c == Color832.Blue && q.s == Status832.Inactive
		&& q.cs.length == 2 && q.cs[0] == Color832.Green);
}

jsonSide();
cborSide();
if (failures > 0) exit(1);
