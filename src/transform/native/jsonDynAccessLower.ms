// JSON Dynamic Access Lowering — rewrite JsonValue.prop → get(obj, "prop")
// + JsonValue → primitive conversions (HiddenStdConv → extension method calls)
//
// Runs after builtinLower, before extensionMethodLower.
// Checker marks unknown properties on JsonValue with nativeName="__jsonDynAccess".
// Checker inserts HiddenStdConv for JsonValue → string/number/boolean/int32.
// This transform rewrites both to pure MetaScript extension method calls.

import { Node, NodeKind, MemberExprData, HiddenStdConvData, NodeFlag, TypeKind } from "../../ast/node";
import { unwrapRef } from "../../checker/types";
import { TransformContext } from "../context";
import { findExtension } from "../../checker/context";
import { walkNode } from "../walker";
import { makeIdent, makeCall, makeString, makeMember } from "../util";

// Map target TypeKind → pure MetaScript extension method name (from std/core/json/accessors.ms)
function jsonAccessorName(kind: TypeKind): string {
	return match (kind) {
		TypeKind.String => "asString",
		TypeKind.Number => "asNumber",
		TypeKind.Boolean => "asBool",
		TypeKind.Int32 => "asInt",
		_ => "",
	};
}

export function lowerJsonDynAccess(program: Node, ctx: TransformContext): Node {
	const result = walkNode(program, (node: Node): Node => {
		// Dynamic member access: obj.prop → get(obj, "prop")
		// Calls the pure MetaScript extension method directly
		if (node.kind === NodeKind.MemberExpr) {
			const d = node.data as MemberExprData;
			if (node.resolvedSym !== null && node.resolvedSym.nativeName === "__jsonDynAccess") {
				const loc = node.location;
				// Resolve "get" extension method from registry for correct mangled name
				let getIdent = makeIdent("get", loc);
				if (ctx.checkerCtx !== null && ctx.checkerCtx.extensionRegistry !== null) {
					const ext = findExtension(ctx.checkerCtx.extensionRegistry, "JsonValue", "get");
					if (ext !== null && ext.sym !== null) {
						getIdent = makeIdent(ext.sym.name, loc);
						getIdent.resolvedSym = ext.sym;
					}
				}
				const call = makeCall(getIdent, [d.object, makeString(d.property, loc)], loc);
				call.nodeType = node.nodeType;
				return call;
			}
		}
		// JsonValue → primitive conversion: HiddenStdConv(JsonValue, string) → asString(expr)
		if (node.kind === NodeKind.HiddenStdConv && (node.flags & NodeFlag.Sem) !== 0) {
			const d = node.data as HiddenStdConvData;
			if (d.convExpr.nodeType !== null && d.convType !== null) {
				const srcInner = unwrapRef(d.convExpr.nodeType);
				if (srcInner !== null && (srcInner.typeName === "JsonValue" || srcInner.typeName === "JsonValueData")) {
					const accessor = jsonAccessorName(d.convType.kind);
					if (accessor !== "") {
						const loc = node.location;
						// Resolve the extension method from registry
						let accIdent = makeIdent(accessor, loc);
						if (ctx.checkerCtx !== null && ctx.checkerCtx.extensionRegistry !== null) {
							const ext = findExtension(ctx.checkerCtx.extensionRegistry, "JsonValue", accessor);
							if (ext !== null && ext.sym !== null) {
								accIdent = makeIdent(ext.sym.name, loc);
								accIdent.resolvedSym = ext.sym;
							}
						}
						const call = makeCall(accIdent, [d.convExpr], loc);
						call.nodeType = d.convType;
						return call;
					}
				}
			}
		}
		return node;
	});
	return result;
}
