import { compileRaiser, runRaiser } from "../../compiler/compile";
import { newCliOptions } from "../../compiler/options";
import { mkdirExclusive, removeAll, writeFile } from "std/fs";
import { tmpDir } from "std/os";

interface CharLoop {
	allocations: int64;
	problem: string;
}

function charLoop(iterations: int32): CharLoop {
	const dir = tmpDir() + "/ms-asciiCharsInterned-" + String(Math.floor(Math.random() * 1000000000));
	if (!mkdirExclusive(dir).ok) throw new Error(`cannot create ${dir}`);
	try {
		const file = dir + "/main.ms";
		const source = `const PUNCTUATION = "-.~:/";
function run(n: int32): int32 {
	const text = "a-b.c~d";
	let hits: int32 = 0;
	for (let i: int32 = 0; i < n; i++) {
		const at = i % 7;
		if (PUNCTUATION.indexOf(String.fromCharCode(text.charCodeAt(at) as int32)) >= 0) hits++;
		if (text.charAt(at) == "-") hits++;
	}
	return hits;
}
console.log(run(${iterations}).toString());
`;
		if (!writeFile(file, source).ok) throw new Error(`cannot write ${file}`);
		const printed: string[] = [];
		const ctx = runRaiser(compileRaiser(file, newCliOptions()), [file], (text: string): void => { printed.push(text); }, false);
		const expected = (iterations / 7 * 4).toString();
		if (ctx.lastError != "" || printed.join("|") != expected) return { allocations: 0, problem: `${ctx.lastError} printed ${printed.join("|")}, not ${expected}` };
		return { allocations: ctx.arrayHeap.mem.allocations, problem: "" };
	} finally {
		removeAll(dir);
	}
}

test "a one-character ASCII string from fromCharCode or charAt is the interned constant, allocated once per process" {
	const few = charLoop(7);
	const many = charLoop(700);
	assert few.problem == "" && many.problem == "", few.problem + many.problem;
	assert many.allocations - few.allocations == 0, `${many.allocations - few.allocations} allocations`;
}
