import { compileToCWithStd, compileProjectToJSWithStd } from "../helpers";

function refusalMiss(source: string, message: string): string {
	const c = compileToCWithStd(source);
	if (c.ok || !c.error.contains(message)) return c.ok ? "C accepted: " + source : c.error;
	const js = compileProjectToJSWithStd([{ entryPath: "test/identity.ms", entrySource: source }], "test/identity.ms");
	return js.startsWith("ERROR:") && js.contains(message) ? "" : "JS: " + js;
}

function escapeThrough(className: string): string {
	return `class ${className} { v: int32 = 0; }
class Box { t: ${className} = new ${className}(); }
function f(b: Readonly<Box>): void {
	const x = b.t;
	x.v = 5;
}
f(new Box());`;
}

test "a user class spelled like a std/meta graph class keeps the read-only view" {
	for (const name of ["Type", "Symbol", "Node", "Inner"]) {
		const miss = refusalMiss(escapeThrough(name), `cannot write through Readonly<${name}>`);
		assert miss == "", miss;
	}
}

test "a user Node below a user Type is a read-only view, not an AST back-edge" {
	const miss = refusalMiss(`class Node { v: int32 = 0; }
class Type { n: Node = new Node(); }
class Box { t: Type = new Type(); }
function f(b: Readonly<Box>): void {
	b.t.n.v = 5;
}
f(new Box());`, "cannot write through Readonly<Node>");
	assert miss == "", miss;
}

test "an object cast from a user class spelled Node reads only its own fields" {
	for (const name of ["Node", "Inner"]) {
		const miss = refusalMiss(`class ${name} { v: int32 = 1; }
interface Wide { v: int32; w: int32; }
const n = new ${name}();
const x = n as Wide;
console.log(x.w);`, "it has no field 'w'");
		assert miss == "", miss;
	}
}

test "an unresolved type name is refused however it is spelled" {
	for (const spelled of ["Missing__Type", "Missing__Type<int32>", "MissingType"]) {
		const head = spelled.indexOf("<") >= 0 ? spelled.substring(0, spelled.indexOf("<")) : spelled;
		const miss = refusalMiss(`function f(x: ${spelled}): int32 { return 1; }
console.log(f(5));`, `Unresolved type '${head}'`);
		assert miss == "", miss;
	}
}
