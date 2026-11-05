// @stdout: comptime vm vm a | vm | runtime true true true true
// note: a body's `when (raiser) { … } else { … }` keeps both blocks through the check; the comptime engine runs the raiser block of a helper the build checked (same module, imported, generic instance), and every backend runs its own block at run time.
import { importedWhere, firstOf } from "./lib";

function where(): string {
	let out = "";
	when (raiser) {
		out = "vm";
	} else {
		out = "native";
	}
	return out;
}

const atCompile = @comptime {
	return `${where()} ${importedWhere()} ${firstOf<string>(["a", "z"], "-")}`;
};
const vmHere = @comptime { return where(); };

let expected = "native";
let expectedFirst = "z";
when (raiser) {
	expected = "vm";
	expectedFirst = "a";
}
console.log(`comptime ${atCompile} | ${vmHere} | runtime ${where() == expected} ${importedWhere() == expected} ${firstOf<string>(["a", "z"], "-") == expectedFirst} ${firstOf<int32>([], 7) == 7}`);
