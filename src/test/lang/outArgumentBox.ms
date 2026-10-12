import { compileProjectToJSWithStd, MapEntry } from "../helpers";

struct OutPt731 { x: int32; y: int32; }
class OutCell731 { v: int32 = 0; }

function fill731(out a: int32, out s: string, out p: OutPt731): void { a = 5; s = "q"; p = { x: 1, y: 2 }; }
function put731(out a: int32): void { a = 7; }

test "an unassigned local filled through out holds the value" {
	let a: int32;
	let s: string;
	let p: OutPt731;
	fill731(out a, out s, out p);
	assert a == 5;
	assert s == "q";
	assert p.y == 2;
}

test "out reaches a field and an element" {
	const c = new OutCell731();
	const xs: int32[] = [1, 2, 3];
	put731(out c.v);
	put731(out xs[1]);
	assert c.v == 7;
	assert xs[1] == 7;
}

function jsOf731(source: string): string {
	const entries: MapEntry[] = [{ entryPath: "test/outBox.ms", entrySource: source }];
	return compileProjectToJSWithStd(entries, "test/outBox.ms");
}

test "JS boxes a local filled through out at its declaration" {
	const js = jsOf731("struct P731 { x: int32; y: int32; }\nfunction fill(out a: int32, out s: string, out p: P731): void { a = 5; s = \"q\"; p = { x: 1, y: 2 }; }\nfunction main(): int32 { let a731: int32; let s731: string; let p731: P731; fill(out a731, out s731, out p731); return a731 + p731.y; }\nprocess.exit(main());\n");
	assert js.contains("let a731 = ["), js;
	assert js.contains("let s731 = ["), js;
	assert js.contains("let p731 = ["), js;
}

test "JS passes the location of a field or element written with out" {
	const js = jsOf731("class C731 { v: int32 = 0; }\nfunction put(out a: int32): void { a = 7; }\nfunction main(): int32 { const c731 = new C731(); const xs731: int32[] = [1, 2]; put(out c731.v); put(out xs731[1]); return c731.v + xs731[1]; }\nprocess.exit(main());\n");
	assert !js.contains("unsupported"), js;
	assert js.contains("[c731, \"v\"]"), js;
}
