import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const m = await import(pathToFileURL(resolve(process.argv[2])).href);

const surface = ["addI32", "lowByte", "echo64", "echoU64", "not", "half", "join2", "sumVec", "countTrue", "bigSum", "reach", "sumSpan", "evalCb", "testCb"];
const missing = surface.filter((name) => typeof m[name] !== "function");
console.log(missing.length == 0 ? "exports: ok" : `exports: missing ${missing.join(",")}`);
if (missing.length > 0) process.exit(1);

function attempt(label, call) {
	try {
		console.log(`${label}: ok ${String(call())}`);
	} catch (e) {
		console.log(`${label}: ${e.name}: ${e.message}`);
	}
}

const seg = (stop) => ({ start: { x: 1, y: 2 }, stop, tag: "t", lit: true });

attempt("valid", () => m.addI32(40, 2));
attempt("string", () => m.addI32("5", 2));
attempt("missing", () => m.addI32(1));
attempt("range", () => m.addI32(2147483648, 0));
attempt("fraction", () => m.addI32(1.5, 0));
attempt("nan", () => m.addI32(NaN, 0));
attempt("u8", () => m.lowByte(256));
attempt("i64 number", () => m.echo64(5));
attempt("u64 range", () => m.echoU64(-1n));
attempt("bool", () => m.not(1));
attempt("float nan", () => m.half(NaN));
attempt("str", () => m.join2("a", 7));
attempt("struct null", () => m.reach(null));
attempt("struct nested", () => m.reach({ start: { x: 1, y: 2 }, tag: "t", lit: true }));
attempt("struct leaf", () => m.reach(seg({ x: 4 })));
attempt("struct ok", () => m.reach(seg({ x: 4, y: 6 })));
attempt("vec text", () => m.sumVec("123"));
attempt("vec element", () => m.sumVec([1, "2", 3]));
attempt("vec range", () => m.sumVec([1, 2.5]));
attempt("bool vec", () => m.countTrue([true, 1]));
attempt("i64 vec", () => m.bigSum([1n, 2]));
attempt("span shape", () => m.sumSpan({ base: [1, 2], off: 0.5, len: 1 }));
attempt("span empty", () => m.sumSpan({ base: [1, 2], off: 7, len: 0 }));
attempt("callback type", () => m.evalCb(1, "nope"));
attempt("callback result", () => m.evalCb(1, () => "x"));
attempt("callback bool", () => m.testCb(1, () => 1));
