import { compileToCWithStd } from "../helpers";

const TYPES = `struct Tag { bytes: uint8[8]; }
struct Outer { tag: Tag; level: uint16; }
function make(): Tag { return { bytes: [1, 2, 3, 4, 5, 6, 7, 200] }; }
`;

function cOf(body: string): string {
	const c = compileToCWithStd(TYPES + body);
	return c.ok ? c.value : "error: " + c.error;
}

function declOf(c: string, name: string): string {
	const at = c.indexOf(" " + name + "_1_;");
	if (at < 0) return "";
	return c.slice(c.lastIndexOf("\n", at) + 1, at);
}

test "comptimeBlockStaticType: an unannotated block takes the struct its body returns" {
	const c = cOf(`function main(): void {
		const untyped = @comptime { return make(); };
		const typed: Tag = @comptime { return make(); };
		console.log(untyped.bytes[7] + typed.bytes[7]);
	}
	main();`);
	assert declOf(c, "untyped") != "" && declOf(c, "untyped") == declOf(c, "typed"), c.slice(0, 400);
	assert !c.includes("__anon"), c.slice(0, 400);
}

test "comptimeBlockStaticType: a nested struct, a sized array of structs and a narrow scalar keep their types" {
	const c = cOf(`function main(): void {
		const outer = @comptime { return { tag: make(), level: 300 } as Outer; };
		const pair = @comptime { const t = make(); const two: Tag[2] = [t, t]; return two; };
		const small = @comptime { return 5 as uint8; };
		console.log(outer.level, pair[1].bytes[0], small);
	}
	main();`);
	assert declOf(c, "outer").includes("Outer"), declOf(c, "outer");
	assert declOf(c, "pair").includes("msSizedArray_Tag"), declOf(c, "pair");
	assert declOf(c, "small").includes("uint8_t"), declOf(c, "small");
	assert !c.includes("__anon"), c.slice(0, 400);
}
