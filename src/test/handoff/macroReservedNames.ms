import { compileToCWithStd, compileToJSWithStd } from "../helpers";

const needle = "is reserved for the compiler's macro programs";

function refusal(source: string, label: string): string {
	const c = compileToCWithStd(source);
	if (c.ok || !c.error.includes(needle)) return label + " (C): " + (c.ok ? "accepted" : c.error);
	const js = compileToJSWithStd(source);
	if (js.ok || !js.error.includes(needle)) return label + " (JS): " + (js.ok ? "accepted" : js.error);
	return "";
}

test "macroReservedNames: declaring a name the compiler seeds into macro programs is an error naming it" {
	const bad = [
		refusal(`
import { Node } from "std/meta";
class $Node { n: int32 = 1; }
export macro m(x: Node): Node { return quote { 1 }; }
const v: int32 = m(0);
console.log(v);
`, "class $Node beside a macro"),
		refusal(`
import { Node } from "std/meta";
enum $NodeKind { A, B }
export macro m(x: Node): Node { return quote { 1 }; }
const v: int32 = m(0);
console.log(v);
`, "enum $NodeKind beside a macro"),
		refusal(`
class $DeclKind { n: int32 = 1; }
@comptime { const k: int32 = 3; console.log(k); }
`, "class $DeclKind beside a comptime block"),
	].filter((r: string): boolean => r != "").join("\n");
	assert bad == "", bad;
}

test "macroReservedNames: a module with no macro program may spell the name" {
	const c = compileToCWithStd(`
class $Node { n: int32 = 1; }
console.log(new $Node().n);
`);
	assert c.ok, c.error;
}
