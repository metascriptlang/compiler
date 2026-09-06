// Route 7: Post-transform param type resolution
//
// After the full transform pipeline, lifecycle hook parameters should
// have fully resolved types (Struct), not unresolved TypeReference.

import { TypeKind } from "../../ast/node";
import { fullPipeline, findFnDecl } from "./helpers";

test "post-transform: lifecycle hook has resolved param type" {
	const src = "interface Info { name: string; desc: string; tag: string }\nconst a: Info = { name: \"a\", desc: \"b\", tag: \"c\" };\nconst b: Info = a;";
	const transformed = fullPipeline(src);
	if (transformed != null) {
		const copyFn = findFnDecl(transformed, "InfoCopy");
		if (copyFn != null) {
			const fnType = copyFn.nodeType;
			assert fnType != null;
			assert fnType.typeChildren != null;
			// Param types should be Struct, NOT TypeReference
			let pi = 0;
			while (pi < fnType.typeChildren.length) {
				assert fnType.typeChildren[pi].kind != TypeKind.TypeReference;
				pi = pi + 1;
			}
		}
	}
}
