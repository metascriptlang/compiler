import { flowRowsText, flowsEnable } from "../../compiler/flows";
import { factsCheckEnable, factsCheckMisses } from "../../transform/moduleFacts";
import { compileToC, compileToJS } from "../helpers";

const NULLABLE = "function pa(k: int32): string | null { if (k == 1) return \"c\"; return null; }\n";

const AWAITING_ACTOR = `
actor R {
	items: number[] = [10, 20, 30];
	sum(): number {
		const r = await spawn(() => {
			let t: number = 0;
			for (const v of this.items) { t = t + v; }
			return t;
		});
		return r;
	}
}
`;

const GATED_FEATURES = [
	NULLABLE + "function f(): string { const a = pa(1); return a ?? \"N\"; }\n",
	"function f(s: string): int32 {\n\tswitch (s) {\n\t\tcase \"a\": return 1;\n\t\tcase \"b\": return 2;\n\t\tdefault: return 3;\n\t}\n}\n",
	"function g(): void {}\nfunction f(): int32 { defer g(); return 1; }\n",
	"function f(xs: int32[]): int32[] { return [...xs, 1]; }\n",
];

const ASYNC_AWAIT = "async function g(): Promise<int32> { return 1; }\nasync function f(): Promise<int32> { const v = await g(); return v + 1; }\n";

function skips(rows: string, pass: string): number {
	for (const line of rows.split("\n")) {
		const cols = line.split("\t");
		if (cols.length == 4 && cols[1] == `skip.pass.${pass}` && cols[2] == "count") return parseFloat(cols[3]);
	}
	return 0;
}

test "a module without ?? skips the nullish pass, and a module with one runs it" {
	flowsEnable(true);
	const plain = compileToC(NULLABLE + "function f(): string { const a = pa(1); return a != null ? a : \"N\"; }\n");
	const plainRows = flowRowsText();
	flowsEnable(true);
	const coalesced = compileToC(NULLABLE + "function f(): string { const a = pa(1); return a ?? \"N\"; }\n");
	const coalescedRows = flowRowsText();
	flowsEnable(false);
	assert plain.ok, plain.ok ? "" : plain.error;
	assert coalesced.ok, coalesced.ok ? "" : coalesced.error;
	assert skips(plainRows, "lowerNullishCoalesce") == 1;
	assert skips(coalescedRows, "lowerNullishCoalesce") == 0;
	assert skips(plainRows, "lowerAwait") == 1 && skips(plainRows, "lowerAsync") == 1;
}

test "an actor method that awaits without async reaches lowerAsync through lowerActorPre" {
	factsCheckEnable(true);
	flowsEnable(true);
	const c = compileToC(AWAITING_ACTOR);
	const rows = flowRowsText();
	flowsEnable(false);
	const misses = factsCheckMisses();
	factsCheckEnable(false);
	assert c.ok, c.ok ? "" : c.error;
	assert misses == 0;
	assert skips(rows, "lowerAsync") == 0 && skips(rows, "lowerAsyncBridge") == 0 && skips(rows, "lowerGenerator") == 0;
}

test "MSC_FACTS_CHECK finds no gated pass skipping a module that holds its feature, on C and JS" {
	for (const src of GATED_FEATURES) {
		factsCheckEnable(true);
		const c = compileToC(src);
		const cMisses = factsCheckMisses();
		factsCheckEnable(true);
		const js = compileToJS(src);
		const jsMisses = factsCheckMisses();
		factsCheckEnable(false);
		assert c.ok, c.ok ? src : c.error;
		assert js.ok, js.ok ? src : js.error;
		assert cMisses == 0 && jsMisses == 0, src;
	}
	factsCheckEnable(true);
	const c = compileToC(ASYNC_AWAIT);
	const misses = factsCheckMisses();
	factsCheckEnable(false);
	assert c.ok, c.ok ? "" : c.error;
	assert misses == 0;
}
