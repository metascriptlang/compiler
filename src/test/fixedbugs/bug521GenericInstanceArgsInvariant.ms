// bug521 — two instances of one generic class interconverted whatever their type arguments
//
// Symptom:    a `Box<int32>` passed as a `Box<string>` argument, initialised a `Box<string>`
//             declaration and came back from a `Box<string>` function; C read the int32 field as
//             an msString (arbitrary memory), JS printed `[5]`. An overloaded `f(b: Box<int64>)`
//             took a `Box<int32>` too.
//
// Root cause: the Ref arm of isAssignable accepted any two pointees of the same name before the
//             instance arguments were compared, the GenericInstance arm related those arguments
//             covariantly, and typeRelation scored any related argument pair as Exact.
//
// Fix:        the reference's tyGenericInst relation (sigmatch.nim typeRel, trNoCovariance): the
//             same-name shortcut skips an instance, and every argument pair must be the same type
//             (an open element still relates) for assignment and for overload scoring alike.

import { hasError } from "../handoff/helpers";
import { compileToC } from "../helpers";

const BOX521 = "class Box<T> {\n\tv: T;\n\tconstructor(v: T) { this.v = v; }\n}\n";

test "bug521: a Box<int32> argument is refused for a Box<string> parameter" {
	assert hasError(BOX521 + "function take(x: Box<string>): string { return x.v; }\nconst b = new Box<int32>(5);\nconst s = take(b);\n", "Argument type mismatch in 'take' arg 0");
}

test "bug521: a Box<int32> is refused by a Box<string> declaration" {
	assert hasError(BOX521 + "const b = new Box<int32>(5);\nconst c: Box<string> = b;\n", "Type 'Box' is not assignable to type 'Box'");
}

test "bug521: a Box<int32> is refused as a Box<string> return value" {
	assert hasError(BOX521 + "function back(x: Box<int32>): Box<string> { return x; }\n", "Type 'Box' is not assignable to type 'Box'");
}

test "bug521: a wider integer argument does not relate either" {
	assert hasError(BOX521 + "const b = new Box<int32>(5);\nconst c: Box<int64> = b;\n", "Type 'Box' is not assignable to type 'Box'");
}

test "bug521: an overload taking another instance does not match" {
	assert hasError(BOX521 + "function f(b: Box<int64>): string { return \"i\"; }\nfunction f(s: string): string { return s; }\nconst b = new Box<int32>(5);\nconst r = f(b);\n", "No matching overload for 'f'");
}

test "bug521: the same instance stays assignable" {
	const r = compileToC(BOX521 + "function take(x: Box<string>): string { return x.v; }\nconst b = new Box<string>(\"a\");\nconst c: Box<string> = b;\nconst s = take(c);\n");
	assert r.ok, r.error;
}
