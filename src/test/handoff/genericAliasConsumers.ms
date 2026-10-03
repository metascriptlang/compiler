import { errorCount } from "../handoff/helpers";
import { compileToC, compileToJS } from "../helpers";

const BRAND = "type Brand661<T> = T;\nfunction mk661<T>(o: T): Brand661<T> { return o; }\n";

function emitC(src: string): string {
	const r = compileToC(src);
	return r.ok ? r.value : "error: " + r.error;
}

function emitJs(src: string): string {
	const r = compileToJS(src);
	return r.ok ? r.value : "error: " + r.error;
}

test "genericAliasConsumers: a value fits a nullable slot written through a bare-parameter alias instance" {
	assert errorCount(BRAND + "const s: Brand661<string | null> = \"hi\";\nconst n: Brand661<number | null> = 5;\nconst z: Brand661<string | null> = null;\n") == 0;
	assert errorCount(BRAND + "function use661(x: Brand661<string | null>): void {}\nuse661(\"hi\");\nuse661(null);\n") == 0;
}

test "genericAliasConsumers: a null check narrows a nullable bare-parameter alias instance to its payload" {
	assert errorCount(BRAND + "const s = mk661<string | null>(\"hi\");\nif (s !== null) { const k: int32 = s.length; }\n") == 0;
	assert errorCount(BRAND + "const n: Brand661<number | null> = 5;\nif (n !== null) { const m: number = n + 1; }\n") == 0;
}

test "genericAliasConsumers: typeof and assignment narrow a union bare-parameter alias instance to a member" {
	assert errorCount(BRAND + "function f661(u: Brand661<string | number>): int32 { if (typeof u === \"string\") return u.length; return 0; }\n") == 0;
	assert errorCount(BRAND + "const a: Brand661<string | number> = \"abc\";\nconst k: int32 = a.length;\n") == 0;
}

test "genericAliasConsumers: for of over an array bare-parameter alias instance iterates the array on both backends" {
	const src = BRAND + "let t: number = 0;\nfor (const e of mk661<number[]>([1, 2])) t = t + e;\nconsole.log(t);\n";
	const js = emitJs(src);
	assert js.indexOf("error:", 0) < 0, js;
	assert js.indexOf("toItems", 0) < 0, js;
	const c = emitC(src);
	assert c.indexOf("error:", 0) < 0, c;
}

test "genericAliasConsumers: C hands an array bare-parameter alias instance to a runtime array helper as its pointer" {
	const out = emitC(BRAND + "const a = mk661<number[]>([1, 2]);\na.push(3);\nconst b = [...a, 9];\nconsole.log(a.length + b.length);\n");
	assert out.indexOf("error:", 0) < 0, out;
	assert out.indexOf("msNumberArrayPush(&", 0) < 0, out;
	assert out.indexOf("msNumberArrayPush(", 0) >= 0, out;
}

test "genericAliasConsumers: JS reads a narrowed nullable bare-parameter alias instance as native null" {
	const out = emitJs(BRAND + "const s = mk661<string | null>(\"hi\");\nif (s !== null) console.log(s);\nconsole.log(s ?? \"d\");\n");
	assert out.indexOf("error:", 0) < 0, out;
	assert out.indexOf(".present", 0) < 0, out;
}

test "genericAliasConsumers: a boolean bare-parameter alias instance is a condition as it is" {
	const js = emitJs(BRAND + "const b = mk661<boolean>(true);\nif (b) console.log(\"y\");\n");
	assert js.indexOf("error:", 0) < 0, js;
	assert js.indexOf("byteLength", 0) < 0, js;
	const c = emitC(BRAND + "const b = mk661<boolean>(true);\nif (b) console.log(\"y\");\n");
	assert c.indexOf("error:", 0) < 0, c;
	assert c.indexOf("byteLength", 0) < 0, c;
}
