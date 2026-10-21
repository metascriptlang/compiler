// Route 7: Post-transform param type resolution
//
// After the full transform pipeline, lifecycle hook parameters should
// have fully resolved types (Struct), not unresolved TypeReference.

import { TypeKind } from "../../ast/node";
import { fullPipeline, findFnDecl } from "./helpers";

test "post-transform: lifecycle hook has resolved param type" {
	const src = "interface Info { name: string; desc: string; tag: string }\nconst a: Info = { name: \"a\", desc: \"b\", tag: \"c\" };\nconst b: Info = a;";
	const transformed = fullPipeline(src);
	assert transformed != null;
	const copyFn = findFnDecl(transformed, "InfoCopy");
	assert copyFn != null;
	const fnType = copyFn.nodeType;
	assert fnType != null;
	assert fnType.typeChildren.length == 2;
	// Param types should be resolved, NOT TypeReference
	for (const param of fnType.typeChildren) {
		assert param.kind != TypeKind.TypeReference;
	}
}
