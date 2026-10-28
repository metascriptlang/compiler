// E2E: a search through a Readonly receiver calls the typed array routine, as a mutable receiver does,
// and never instantiates the generic body, which has no text or number operator in its module.

import { compileToC } from "../helpers";

test "E2E C: includes and indexOf on a Readonly string vec call the typed routines" {
	const c = compileToC(`
		struct Hub { tables: Vec<string>; }
		function has(hub: Readonly<Hub>, name: string): boolean {
			return hub.tables.includes(name) || hub.tables.indexOf(name) > 5;
		}
		function main(): void {
			const hub: Hub = { tables: ["a", "b"] };
			console.log(has(hub, "b").toString());
		}
	`);
	assert c.ok;
	assert c.value.contains("msStringArrayIncludes("), "typed includes missing";
	assert c.value.contains("msStringArrayIndexOf("), "typed indexOf missing";
	assert !c.value.contains("Vec_includes_"), "generic includes instantiated";
	assert !c.value.contains("Vec_indexOf_"), "generic indexOf instantiated";
}

test "E2E C: includes on a Readonly number vec and a mutable one call the same typed routine" {
	const c = compileToC(`
		struct Hub { nums: Vec<number>; }
		function ro(hub: Readonly<Hub>): boolean { return hub.nums.includes(3); }
		function rw(hub: Hub): boolean { return hub.nums.includes(3); }
		function main(): void {
			const hub: Hub = { nums: [1, 3] };
			console.log(ro(hub).toString() + rw(hub).toString());
		}
	`);
	assert c.ok;
	assert c.value.contains("msNumberArrayIncludes("), "typed includes missing";
	assert !c.value.contains("Vec_includes_"), "generic includes instantiated";
}
