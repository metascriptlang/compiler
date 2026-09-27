import { splitTopLevel } from "../../utils/string";
import { monoConcreteTypeName, monoSubstAnnotation } from "../../monomorphize/clone";
import { createArc, createArray, createRef, createStruct, int32Type } from "../../checker/types";

test "annotation boundaries: nested delimiters and arrows never create an extra argument" {
	const atoms = [
		"string",
		"number",
		"Map<string, int32>",
		"(s: string) => Result<string, string>",
		"(x: number) => (y: string) => boolean",
		"[int32, string]",
	];
	for (const atom of atoms) {
		const singleton = splitTopLevel(atom, ",");
		assert singleton.length == 1, atom;
		assert singleton[0] == atom, atom;
		const nested = "Container<" + atom + ">";
		const source = "string, " + atom + ", " + nested;
		const parts = splitTopLevel(source, ",");
		assert parts.length == 3, source;
		assert parts[0] == "string", source;
		assert parts[1] == atom, source;
		assert parts[2] == nested, source;
	}
}

test "annotation identity: ownership constructors survive generic substitution" {
	for (const name of ["Payload", "OtherPayload"]) {
		const payload = createStruct(name, ["value"], [int32Type()], true);
		const plain = monoConcreteTypeName(createRef(payload));
		const atomic = monoConcreteTypeName(createArc(payload));
		assert plain == name;
		assert atomic == "Arc<" + name + ">";
		assert atomic != plain;
		assert monoConcreteTypeName(createArray(payload)) == "Vec<" + name + ">";
		assert monoConcreteTypeName(createRef(createArray(payload))) == "Array<" + name + ">";
		assert monoSubstAnnotation("Promise<T>", "T", plain) == "Promise<" + name + ">";
		assert monoSubstAnnotation("Promise<T>", "T", atomic) == "Promise<Arc<" + name + ">>";
	}
}

test "annotation substitution: only complete parameter identifiers are replaced" {
	const payload = "Arc<Payload>";
	assert monoSubstAnnotation("Map<T, Target<T>>", "T", payload) == "Map<Arc<Payload>, Target<Arc<Payload>>>";
	assert monoSubstAnnotation("(value: T) => Promise<T>", "T", payload) == "(value: Arc<Payload>) => Promise<Arc<Payload>>";
	assert monoSubstAnnotation("Target<T> | T[]", "T", payload) == "Target<Arc<Payload>> | Arc<Payload>[]";
}
