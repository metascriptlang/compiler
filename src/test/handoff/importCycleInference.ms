import { checkProjectDiagnostics, MapEntry } from "../helpers";
import { lookupModuleCtx } from "../../checker/instantiate";
import { canonicalModulePath } from "../../module/loader";

function errorsIn(path: string): string[] {
	const ctx = lookupModuleCtx(canonicalModulePath(path));
	const messages: string[] = [];
	if (ctx == null) {
		messages.push(`internal: ${path} was not checked`);
		return messages;
	}
	for (const e of ctx.errors) messages.push(e.message);
	return messages;
}

function hasMessage(messages: string[], text: string): boolean {
	for (const m of messages) {
		if (m.contains(text)) return true;
	}
	return false;
}

const twiceModule = `import { half } from "./lib/half";
export function twice() { return base() * 2; }
function base() { return 21; }
console.log(\`\${half()}\`);
`;

function halfModule(slot: string): string {
	return `import { twice } from "../main";
export function half() { const t = twice(); const s: ${slot} = t; return s; }
`;
}

test "importCycleInference: the module checked first reads a return type the other module infers, and a slot that does not fit is refused" {
	const entries: MapEntry[] = [
		{ entryPath: "src/main.ms", entrySource: twiceModule },
		{ entryPath: "src/lib/half.ms", entrySource: halfModule("string") },
	];
	checkProjectDiagnostics(entries, "src/main.ms");
	const messages = errorsIn("src/lib/half.ms");
	assert hasMessage(messages, "Type 'int32' is not assignable to type 'string'"), messages.join("\n");
	assert errorsIn("src/main.ms").length == 0, errorsIn("src/main.ms").join("\n");
}

test "importCycleInference: the same program with a slot that fits checks clean in both modules" {
	const entries: MapEntry[] = [
		{ entryPath: "src/main.ms", entrySource: twiceModule },
		{ entryPath: "src/lib/half.ms", entrySource: halfModule("number") },
	];
	checkProjectDiagnostics(entries, "src/main.ms");
	assert errorsIn("src/lib/half.ms").length == 0, errorsIn("src/lib/half.ms").join("\n");
	assert errorsIn("src/main.ms").length == 0, errorsIn("src/main.ms").join("\n");
}

test "importCycleInference: the module checked second reads a return type inferred while the first was checked" {
	const entries: MapEntry[] = [
		{ entryPath: "src/main.ms", entrySource: `import { half } from "./lib/half";
export function twice() { return 21 * 2; }
const s: string = half();
console.log(s);
` },
		{ entryPath: "src/lib/half.ms", entrySource: `import { twice } from "../main";
export function half() { return twice() / 2; }
` },
	];
	checkProjectDiagnostics(entries, "src/main.ms");
	const messages = errorsIn("src/main.ms");
	assert hasMessage(messages, "Type 'int32' is not assignable to type 'string'"), messages.join("\n");
}

test "importCycleInference: a const and a method of the other module are typed from their declarations" {
	const entries: MapEntry[] = [
		{ entryPath: "src/main.ms", entrySource: `import { useB } from "./a";
console.log(useB());
` },
		{ entryPath: "src/a.ms", entrySource: `import { readB } from "./b";
export const LIMIT = 4;
export class Counter {
	n: number;
	constructor(n: number) { this.n = n; }
	next() { return this.n + 1; }
}
export function useB(): string { return readB(); }
` },
		{ entryPath: "src/b.ms", entrySource: `import { Counter, LIMIT } from "./a";
export function readB(): string {
	const fromMethod: string = new Counter(4).next();
	const fromConst: string = LIMIT;
	return fromMethod + fromConst;
}
` },
	];
	checkProjectDiagnostics(entries, "src/main.ms");
	const messages = errorsIn("src/b.ms");
	assert messages.length == 2, messages.join("\n");
	assert hasMessage(messages, "is not assignable to type 'string'"), messages.join("\n");
}

test "importCycleInference: return types that read each other across the cycle are refused" {
	const entries: MapEntry[] = [
		{ entryPath: "src/main.ms", entrySource: `import { f } from "./a";
console.log(\`\${f(3)}\`);
` },
		{ entryPath: "src/a.ms", entrySource: `import { g } from "./b";
export function f(n: number) { return n <= 0 ? 0 : g(n - 1); }
` },
		{ entryPath: "src/b.ms", entrySource: `import { f } from "./a";
export function g(n: number) { return n <= 0 ? 1 : f(n - 1); }
` },
	];
	checkProjectDiagnostics(entries, "src/main.ms");
	const messages = errorsIn("src/a.ms");
	assert hasMessage(messages, "cannot infer the return type of 'g': 'f' reads it while 'g' is still being checked (g -> f -> g)"), messages.join("\n");
}
