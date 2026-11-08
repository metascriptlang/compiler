// A session that keeps a module's check replays the types that check accepted behind an interface into the
// next build's fresh tables, so a module checked again classifies the interface with every implementer.
import { platform } from "std/process";
import { checkModuleGraph, createCheckSession, CheckSession } from "../../checker/orchestrator";
import { GcMode } from "../../checker/context";
import { hostTargetInfo, heldBeyond, resetHeldBeyond, unwrapRef } from "../../checker/types";
import { lookupSymbol } from "../../checker/symbol";
import { MapEntry, createMapProvider, loadModuleGraph } from "../../module/loader";
import { resetBuildState } from "../../compiler/buildSession";

const LINK = "export interface Holder { id: int32; }\nexport class Box { id: int32 = 0; other: Holder | null = null; }\nexport function pair(): Box {\n\tconst a = new Box();\n\tconst b = new Box();\n\ta.other = b;\n\tb.other = a;\n\treturn a;\n}\n";
const MAIN = (n: int32): string => `import { pair } from "./link";\nconst p = pair();\np.id = ${n};\n`;

function check(session: CheckSession, link: string, n: int32): void {
	resetHeldBeyond();
	const entries: MapEntry[] = [{ entryPath: "/h/link.ms", entrySource: link }, { entryPath: "/h/main.ms", entrySource: MAIN(n) }];
	const graph = loadModuleGraph("/h/main.ms", createMapProvider(entries));
	checkModuleGraph(graph, "", ".cms", platform, hostTargetInfo(), GcMode.Drc, null, session);
}

function heldBehindHolder(session: CheckSession): string {
	const ctx = session.checks.get("/h/link.ms");
	const sym = ctx != null ? lookupSymbol(ctx.table, "Holder") : null;
	if (sym == null || sym.symbolType == null) return "no Holder";
	return heldBeyond(unwrapRef(sym.symbolType)).map((t): string => t.typeName).join(",");
}

test "a module checked once keeps the types it accepted behind an interface for the next build" {
	resetBuildState();
	const session = createCheckSession();
	check(session, LINK, 1);
	assert heldBehindHolder(session) == "Box", heldBehindHolder(session);
	check(session, LINK, 2);
	assert !session.rechecked.has("/h/link.ms");
	assert heldBehindHolder(session) == "Box", heldBehindHolder(session);
	assert session.heldChanged == "", session.heldChanged;
}

test "a module checked again that accepts other types behind an interface marks the session's lowering stale" {
	resetBuildState();
	const session = createCheckSession();
	check(session, LINK, 1);
	check(session, LINK.replace("\tb.other = a;\n", ""), 1);
	assert session.heldChanged == "", session.heldChanged;
	check(session, LINK.replace("\ta.other = b;\n\tb.other = a;\n", ""), 1);
	assert session.heldChanged == "/h/link.ms", session.heldChanged;
}
