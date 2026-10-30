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
	return mod;
}
