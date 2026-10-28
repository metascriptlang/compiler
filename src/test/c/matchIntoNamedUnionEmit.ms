// E2E C: a match used as a value stored into a declared union alias hands the sink the alias'
// own struct. An arm wrapped as the anonymous `msUnion_*` carrier is a different C type, which
// clang 22 refuses as an incompatible pointer. Paired with lang/matchIntoNamedUnion.ms, which runs it.

import { compileToC } from "../helpers";

function emitFor(disc: string, first: string, second: string): string {
	const c = compileToC(`
		enum K { A, B }
		interface P { ${disc}: ${first}; x: int32; }
		interface Q { ${disc}: ${second}; y: int32; }
		type U = P | Q;
		function pick(n: int32): U {
			const v: U = match (n) {
				1 => ({ ${disc}: ${first}, x: n }),
				_ => ({ ${disc}: ${second}, y: n }),
			};
			return v;
		}
		function main(): void {
			pick(1);
		}
	`);
	return c.ok ? c.value : "";
}

test "E2E C: a match arm stored into an enum-discriminant union alias creates no anonymous carrier" {
	const c = emitFor("kind", "K.A", "K.B");
	assert c != "";
	assert !c.contains("msUnion_");
}

test "E2E C: a match arm stored into a string-discriminant union alias creates no anonymous carrier" {
	const c = emitFor("tag", "\"p\"", "\"q\"");
	assert c != "";
	assert !c.contains("msUnion_");
}
