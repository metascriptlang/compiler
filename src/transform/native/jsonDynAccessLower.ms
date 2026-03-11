// JSON Dynamic Access Lowering — rewrite JsonValue.prop → msJsonGet(obj, "prop")
// + JsonValue → primitive conversions (HiddenStdConv/TypeAssertion → accessor calls)
//
// Runs after builtinLower, before extensionMethodLower.
// Checker marks unknown properties on JsonValue with nativeName="__jsonDynAccess".
// Checker inserts HiddenStdConv for JsonValue → string/number/boolean/int32.
// This transform rewrites both to direct C runtime calls.

import { Node, NodeKind, MemberExprData, ProgramData, HiddenStdConvData, NodeFlag, makeLoc } from "../../ast/node";
import { TypeKind, unwrapRef } from "../../checker/types";
import { TransformContext, hasEmitted } from "../context";
import { walkNode } from "../walker";
import { makeIdent, makeCall, makeString } from "../util";
import { makeEmitNode } from "../../codegen/c/json";

// Map target TypeKind → C runtime accessor function name
function jsonAccessorName(kind: TypeKind): string {
	return match (kind) {
		TypeKind.String => "msJsonAsString",
		TypeKind.Number => "msJsonAsNumber",
		TypeKind.Boolean => "msJsonAsBool",
		TypeKind.Int32 => "msJsonAsInt",
		_ => "",
	};
}

export function lowerJsonDynAccess(program: Node, ctx: TransformContext): Node {
	let needsInclude = false;
	const result = walkNode(program, (node: Node): Node => {
		// Dynamic member access: obj.prop → msJsonGet(obj, "prop")
		if (node.kind === NodeKind.MemberExpr) {
			const d = node.data as MemberExprData;
			if (node.resolvedSym !== null && node.resolvedSym.nativeName === "__jsonDynAccess") {
				needsInclude = true;
				const loc = node.location;
				const call = makeCall(
					makeIdent("msJsonGet", loc),
					[d.object, makeString(d.property, loc)],
					loc
				);
				call.nodeType = node.nodeType;
				return call;
			}
		}
		// JsonValue → primitive conversion: HiddenStdConv(JsonValue, string) → msJsonAsString(expr)
		if (node.kind === NodeKind.HiddenStdConv && (node.flags & NodeFlag.Sem) !== 0) {
			const d = node.data as HiddenStdConvData;
			if (d.convExpr.nodeType !== null && d.convType !== null) {
				const srcInner = unwrapRef(d.convExpr.nodeType);
				if (srcInner !== null && srcInner.kind === TypeKind.Struct && srcInner.typeName === "JsonValue") {
					const accessor = jsonAccessorName(d.convType.kind);
					if (accessor !== "") {
						needsInclude = true;
						const loc = node.location;
						const call = makeCall(makeIdent(accessor, loc), [d.convExpr], loc);
						call.nodeType = d.convType;
						return call;
					}
				}
			}
		}
		return node;
	});
	if (needsInclude && !hasEmitted(ctx, "__jsonInclude")) {
		ctx.emittedHelpers.push("__jsonInclude");
		const pd = result.data as ProgramData;
		pd.programStmts.push(makeEmitNode("/*INCLUDESECTION*/#include \"core/json.h\"\n", makeLoc(0, 0)));
	}
	return result;
}
