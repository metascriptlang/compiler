import { compileToCWithStd, compileProjectToJSWithStd } from "../helpers";

const SHAPES = "struct Box { rate: int32; size: int32; }\ninterface Face { rate: int32; size: int32; }\n";
const NOT_ASSIGNABLE = "is not assignable to type";
const UNION_SPREAD = "cannot spread a value of";

function errorsOf(source: string): string {
	const c = compileToCWithStd(source);
	const js = compileProjectToJSWithStd([{ entryPath: "test/literalArmJoin.ms", entrySource: source }], "test/literalArmJoin.ms");
	if (c.ok && !js.startsWith("ERROR:")) return "";
	if (!c.ok && js.startsWith("ERROR:")) return c.error + "\n" + js;
	return "backends disagree: " + (c.ok ? "C ok" : c.error) + " / " + js;
}

function joinedInto(named: string, arm: string): string {
	return errorsOf(SHAPES + `function f(base: ${named}, on: boolean): ${named} {\n\tconst picked = on ? base : ${arm};\n\treturn picked;\n}\n`);
}

function refusedOnBoth(errors: string, refusal: string): boolean {
	return errors.split(refusal).length - 1 == 2;
}

test "a literal arm with exactly the named type's fields joins as that type" {
	for (const named of ["Box", "Face"]) {
		const errors = joinedInto(named, "{ ...base, size: 9 }");
		assert errors == "", errors;
	}
}

test "a literal arm with an excess field stays a union instead of dropping the field" {
	for (const named of ["Box", "Face"]) {
		assert refusedOnBoth(joinedInto(named, "{ ...base, size: 9, extra: 3 }"), NOT_ASSIGNABLE);
	}
}

test "a literal arm missing a field stays a union instead of inventing the field" {
	for (const named of ["Box", "Face"]) {
		assert refusedOnBoth(joinedInto(named, "{ size: 9 }"), NOT_ASSIGNABLE);
	}
}

test "a literal arm whose field type does not fit stays a union" {
	assert refusedOnBoth(joinedInto("Box", "{ rate: \"x\", size: 9 }"), NOT_ASSIGNABLE);
}

test "a spread of a union of objects is refused at the spread rather than emitted as a field" {
	const source = SHAPES + "struct Wide { rate: int32; size: int32; extra: int32; }\n"
		+ "function f(on: boolean, a: Box, b: Wide): int32 {\n\tconst u = on ? a : b;\n\tconst v = { ...u, rate: 0 };\n\treturn v.rate;\n}\n";
	assert refusedOnBoth(errorsOf(source), UNION_SPREAD);
}
