import { genProjectDispatcher } from "../../codegen/c/index";

function dispatcher(targetOs: string, noMain: boolean): string {
	return genProjectDispatcher(["/p/entry.ms"], "/p/entry.ms", targetOs, noMain, []);
}

test "generated main: every target with a POSIX-style main stores argc and argv for the command-line accessors" {
	for (const os of ["", "emcc", "wasm"]) {
		const c = dispatcher(os, false);
		const at = c.indexOf("int main(");
		assert at >= 0, `${os}: ${c.slice(-300)}`;
		assert c.indexOf("cmdLine = argv;", at) > at && c.indexOf("cmdCount = argc;", at) > at, `${os}: ${c.slice(at)}`;
	}
}

test "generated main: a library output emits no main and leaves the argument globals empty" {
	const c = dispatcher("emcc", true);
	assert !c.includes("int main("), c.slice(-300);
	assert c.includes("int cmdCount;") && c.includes("char** cmdLine;"), c.slice(0, 400);
	assert !c.includes("cmdLine = argv;"), c.slice(-300);
}
