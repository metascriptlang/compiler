import { Node } from "std/meta";

export macro tagModule(mod: Node): Node {
	mod.programStmts.push(quote { console.log("pass call"); });
	mod.programStmts.push(quote {
		if (total > 1) {
			console.log("pass if");
		} else {
			console.log("pass else");
		}
	});
	mod.programStmts.push(quote { counter = counter + 1; });
	mod.programStmts.push(quote { counter += 1; });
	mod.programStmts.push(quote { total as int64; });
	mod.programStmts.push(quote { "tag"; });
	mod.programStmts.push(quote { console.log("counter " + counter); });
	return mod;
}
