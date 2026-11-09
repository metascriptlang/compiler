const FUNCTION_KINDS = ["T", "W"];
const SANITIZER_INTERFACE = "__sanitizer_";
const INTERCEPTOR = "__interceptor_";

export function nmFunctions(nmOutput: string): string[] {
	const functions: string[] = [];
	for (const line of nmOutput.split("\n")) {
		const columns = line.split(" ");
		if (columns.length == 3 && FUNCTION_KINDS.includes(columns[1])) {
			functions.push(columns[2]);
		}
	}
	return functions;
}

function isNewOrDelete(name: string): boolean {
	return name.startsWith("_Znw") || name.startsWith("_Zna") ||
		name.startsWith("_Zdl") || name.startsWith("_Zda");
}

export function dynamicListText(
	functions: string[],
	extras: string[],
): Result<string, string> {
	const exported = new Set<string>();
	for (const name of functions) {
		if (name.contains(INTERCEPTOR) || isNewOrDelete(name)) {
			return Result.err(name + ": interceptor and operator new/delete " +
				"exports need the versioned-function rule, which is not ported");
		}
		if (name.startsWith(SANITIZER_INTERFACE)) { exported.add(name); }
	}
	for (const line of extras) {
		const symbol = line.trimEnd();
		if (symbol != "") { exported.add(symbol); }
	}
	const sorted: string[] = [];
	for (const name of exported) { sorted.push(name); }
	sorted.sort();
	let text = "{\n";
	for (const name of sorted) { text += "  " + name + ";\n"; }
	return Result.ok(text + "};\n");
}
