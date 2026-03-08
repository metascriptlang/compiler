// Debug: trace NewExpr through full pipeline
import { Node, NodeKind, NewExprData, ObjectLiteralData, ProgramData, VariableDeclData } from "../../ast/node";
import { compileToC } from "../helpers";
import { fullPipeline } from "./helpers";

test "Post-pipeline: new Item { value: 42 }" {
	const ast = fullPipeline("class Item { value: number }\nconst x = new Item { value: 42 };");
	if (ast === null) {
		console.log("fullPipeline returned null");
		return;
	}
	const pd = ast.data as ProgramData;
	let i = 0;
	while (i < pd.programStmts.length) {
		const stmt = pd.programStmts[i];
		console.log("post stmt[" + i + "] kind: " + stmt.kind);
		// Check for VariableDecl
		if (stmt.kind === NodeKind.VariableDecl) {
			const vd = stmt.data as VariableDeclData;
			console.log("  init kind: " + vd.initializer.kind + " NewExpr=" + NodeKind.NewExpr);
			if (vd.initializer.kind === NodeKind.NewExpr) {
				const ne = vd.initializer.data as NewExprData;
				console.log("  args: " + ne.newArguments.length);
				if (ne.newArguments.length > 0) {
					console.log("  arg[0] kind: " + ne.newArguments[0].kind + " ObjLit=" + NodeKind.ObjectLiteral);
				}
			}
		}
		i = i + 1;
	}
}

test "E2E C output" {
	const src = "class Item { value: number }\nconst x = new Item { value: 42 };";
	const c = compileToC(src);
	if (c.ok) {
		console.log("=== C ===");
		console.log(c.value);
	} else {
		console.log("FAIL: " + c.error);
	}
}
