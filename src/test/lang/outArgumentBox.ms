import { compileProjectToJSWithStd, MapEntry } from "../helpers";

class OutCell731 { v: int32 = 0; }

function put731(out a: int32): void { a = 7; }

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

test "JS passes the location of a field or element written with out" {
	const js = jsOf731("class C731 { v: int32 = 0; }\nfunction put(out a: int32): void { a = 7; }\nfunction main(): int32 { const c731 = new C731(); const xs731: int32[] = [1, 2]; put(out c731.v); put(out xs731[1]); return c731.v + xs731[1]; }\nprocess.exit(main());\n");
	assert !js.contains("unsupported"), js;
	assert js.contains("[c731, \"v\"]"), js;
}
