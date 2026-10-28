import { createNodeAt, makeLoc, NodeKind } from "std/meta/node";
import { createCGen, createAliveSet, createProc, emitLineDir, readProcStmts, CEmissionFacts } from "../../codegen/c/context";
import { CheckerContext } from "../../checker/context";

function lineDirFor(modulePath: string, trim: boolean): string {
	const facts = new CEmissionFacts();
	facts.moduleNameRoots = { compiler: "/opt/msc", packages: "/cache/extracted", project: "/work/app", uniqueNames: new HashMap<string, string>() };
	facts.trimPaths = trim;
	const g = createCGen(null as unknown as CheckerContext, modulePath, createAliveSet(), facts);
	const p = createProc("probe");
	emitLineDir(g, p, createNodeAt(NodeKind.NullLiteral, { nullPlaceholder: true }, makeLoc(7, 1)));
	return readProcStmts(p);
}

test "with trim off the line directive names the absolute module path" {
	assert lineDirFor("/work/app/src/a.ms", false) == '\n#line 7 "/work/app/src/a.ms"\n';
	assert lineDirFor("/opt/msc/std/array.ms", false) == '\n#line 7 "/opt/msc/std/array.ms"\n';
}

test "with trim on a project module is rooted at the project and a support module under msc" {
	assert lineDirFor("/work/app/src/a.ms", true) == '\n#line 7 "src/a.ms"\n';
	assert lineDirFor("/opt/msc/std/array.ms", true) == '\n#line 7 "msc/std/array.ms"\n';
	assert lineDirFor("/cache/extracted/lib/x.ms", true) == '\n#line 7 "pkg/lib/x.ms"\n';
}

test "with trim on a line directive carries none of the checkout's absolute prefixes" {
	for (const path of ["/work/app/src/a.ms", "/opt/msc/std/array.ms", "/cache/extracted/lib/x.ms"]) {
		const text = lineDirFor(path, true);
		assert !text.includes('"/') && !text.includes("/work/") && !text.includes("/opt/");
	}
}
