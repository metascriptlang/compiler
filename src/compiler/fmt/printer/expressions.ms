// Expression Printers — binary, unary, call, member, literals (object/array), etc.

import {
	Node, NodeKind,
	BinaryExprData, UnaryExprData, UpdateExprData, CallExprData, MemberExprData,
	ArrayAccessData, ObjectLiteralData, ArrayLiteralData, ArrowFunctionData,
	ConditionalExprData, SpreadExprData, NewExprData, TypeAssertionData,
	MatchExprData, MatchCaseData, TryExprData, MoveExprData,
	OutExprData, SizeofExprData, ArrayPatternData, ObjectPatternData, ObjectPatternPropData,
	IdentifierData, MacroInvocationData, FunctionExprData, AwaitExprData, YieldExprData,
} from "../../../ast/node";
import { Token } from "../../../lexer/token";
import { FormatOptions, CommaContext, wantsTrailingComma } from "../options";
import {
	Doc, docText, docGroup, docGroupBreak, docIndent,
	docLine, docSoftLine, docHardLine, docIfBreak, docNil, docJoin,
	docCommaSepList,
} from "../doc";
import { callPrintNode } from "./callbacks";
import { flagHas, buildParamList, paramListInParens } from "./statements";

export function printBinaryExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as BinaryExprData;
	return docGroup([
		printBinaryOperand(d.left, d.operator, false, options),
		docText(" " + d.operator + " "),
		docIndent([docSoftLine(), printBinaryOperand(d.right, d.operator, true, options)]),
	]);
}

// Wrap a binary operand in `(...)` when:
//   - child is also BinaryExpr AND its precedence < parent's, OR
//   - same precedence + parent is left-assoc + child is on the RIGHT, OR
//   - same precedence + parent is right-assoc + child is on the LEFT.
// Lower-precedence non-binary kinds (TypeAssertion, ConditionalExpr,
// AssignmentExpr-as-binary, etc.) are also wrapped via printAtom rules.
function printBinaryOperand(child: Node, parentOp: string, isRight: boolean, options: FormatOptions): Doc {
	if (child === null) return callPrintNode(child, options);
	if (child.kind === NodeKind.TypeAssertion) {
		return docGroup([docText("("), callPrintNode(child, options), docText(")")]);
	}
	if (child.kind !== NodeKind.BinaryExpr) {
		return callPrintNode(child, options);
	}
	const cd = child.data as BinaryExprData;
	const childPrec = opPrecedence(cd.operator);
	const parentPrec = opPrecedence(parentOp);
	let needs = childPrec < parentPrec;
	if (childPrec === parentPrec) {
		const rightAssoc = isRightAssocOp(parentOp);
		if (rightAssoc && !isRight) needs = true;
		if (!rightAssoc && isRight) needs = true;
	}
	if (needs) {
		return docGroup([docText("("), callPrintNode(child, options), docText(")")]);
	}
	return callPrintNode(child, options);
}

function opPrecedence(op: string): number {
	return match (op) {
		"**" => 65,
		"*" | "/" | "%" => 60,
		"+" | "-" => 50,
		"<<" | ">>" | ">>>" => 45,
		"<" | ">" | "<=" | ">=" | "in" | "instanceof" => 40,
		"==" | "!=" | "===" | "!==" => 30,
		"&" => 27,
		"^" => 25,
		"|" => 23,
		"&&" => 20,
		"||" => 10,
		"??" => 8,
		"=" | "+=" | "-=" | "*=" | "/=" | "%=" => 5,
		"|>" => 3,
		_ => 0,
	};
}

function isRightAssocOp(op: string): boolean {
	return match (op) {
		"**" | "=" | "+=" | "-=" | "*=" | "/=" | "%=" => true,
		_ => false,
	};
}

export function printUnaryExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as UnaryExprData;
	return docGroup([docText(d.unaryOp), printAtom(d.operand, options)]);
}

export function printCallExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as CallExprData;
	const args: Doc[] = [];
	for (const arg of d.arguments) {
		args.push(callPrintNode(arg, options));
	}

	const callParts: Doc[] = [printAtom(d.callee, options), docText("(")];
	if (args.length > 0) {
		const argParts = docCommaSepList(args, wantsTrailingComma(options, CommaContext.Params));
		callParts.push(docIndent(argParts));
		callParts.push(docSoftLine());
	}
	callParts.push(docText(")"));
	return docGroup(callParts);
}

export function printMemberExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as MemberExprData;
	let op = ".";
	if (d.isOptional) { op = "?."; }
	return docGroup([
		printAtom(d.object, options),
		docText(op + d.property),
	]);
}

// printAtom: print a sub-expression that the parent needs to bind tighter
// than. For positions where the source grammar requires the child to be a
// PrimaryExpression/MemberExpression (e.g. .field object, call callee,
// arr[i] base, new ctor), low-precedence kinds like `as` need to be
// wrapped in `(...)` — otherwise re-parsing the formatted text yields a
// different AST.
//
// This list grows test-by-test; only kinds proven needed by a roundtrip
// test go in. See src/test/fmt/cases/.
function printAtom(node: Node, options: FormatOptions): Doc {
	if (node !== null && needsAtomParens(node.kind)) {
		return docGroup([docText("("), callPrintNode(node, options), docText(")")]);
	}
	return callPrintNode(node, options);
}

function needsAtomParens(kind: NodeKind): boolean {
	return match (kind) {
		NodeKind.TypeAssertion |
		NodeKind.BinaryExpr |
		NodeKind.ConditionalExpr |
		NodeKind.UnaryExpr |
		NodeKind.UpdateExpr |
		NodeKind.ArrowFunction |
		NodeKind.AwaitExpr |
		NodeKind.YieldExpr |
		NodeKind.MoveExpr |
		NodeKind.TryExpr => true,
		_ => false,
	};
}

export function printUpdateExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as UpdateExprData;
	if (d.isPrefix) {
		return docGroup([docText(d.updateOp), callPrintNode(d.updateArg, options)]);
	}
	return docGroup([callPrintNode(d.updateArg, options), docText(d.updateOp)]);
}

export function printArrayAccess(node: Node, options: FormatOptions): Doc {
	const d = node.data as ArrayAccessData;
	return docGroup([
		printAtom(d.array, options),
		docText("["),
		callPrintNode(d.index, options),
		docText("]"),
	]);
}

// Check if an object key needs quoting — not a valid identifier (contains
// hyphens, dots, starts with digit, empty).
function needsQuote(key: string): boolean {
	if (key.length === 0) return true;
	const first = key.charCodeAt(0);
	if (!((first >= "a".code && first <= "z".code) || (first >= "A".code && first <= "Z".code) || first === "_".code)) return true;
	let j = 1;
	while (j < key.length) {
		const ch = key.charCodeAt(j);
		if (!((ch >= "a".code && ch <= "z".code) || (ch >= "A".code && ch <= "Z".code) || (ch >= "0".code && ch <= "9".code) || ch === "_".code)) return true;
		j = j + 1;
	}
	return false;
}

export function printObjectLiteral(node: Node, options: FormatOptions): Doc {
	const d = node.data as ObjectLiteralData;
	if (d.keys.length === 0) return docText("{}");

	// Force multi-line: objects with 2+ properties, nested complex values,
	// or internal comments (commented-out properties) always expand.
	let forceBreak = d.keys.length >= 2;
	if (!forceBreak) {
		for (const prop of d.properties) {
			if (prop !== null && (prop.kind === NodeKind.ObjectLiteral || prop.kind === NodeKind.ArrayLiteral || prop.kind === NodeKind.ArrowFunction)) {
				forceBreak = true;
			}
			if (prop !== null && prop.comments.length > 0) {
				forceBreak = true;
			}
		}
	}
	// Also check the object node itself for trailing comments
	if (!forceBreak && node.comments.length > 0) {
		forceBreak = true;
	}

	const entries: Doc[] = [];
	for (let i = 0; i < d.keys.length; i += 1) {
		const prop = d.properties[i];
		// Extract leading comments (e.g., commented-out properties) and group them
		// with the following entry so they don't get separator commas.
		const leadingComments: Doc[] = [];
		if (prop !== null && prop.comments.length > 0) {
			const remaining: Token[] = [];
			for (const comment of prop.comments) {
				if (comment.line < prop.location.line) {
					leadingComments.push(docText(comment.value));
					leadingComments.push(docHardLine());
				} else {
					remaining.push(comment);
				}
			}
			prop.comments = remaining;
		}
		let entryDoc: Doc;
		if (d.keys[i] !== "") {
			// Detect shorthand: key === identifier name → emit just the key
			const isShorthand = prop !== null && prop.kind === NodeKind.Identifier
				&& (prop.data as { name: string }).name === d.keys[i];
			if (isShorthand) {
				entryDoc = docText(d.keys[i]);
			} else {
				const keyStr = needsQuote(d.keys[i]) ? "\"" + d.keys[i] + "\"" : d.keys[i];
				entryDoc = docGroup([
					docText(keyStr + ": "),
					callPrintNode(prop, options),
				]);
			}
		} else {
			entryDoc = callPrintNode(prop, options);
		}
		if (leadingComments.length > 0) {
			leadingComments.push(entryDoc);
			entries.push(docGroup(leadingComments));
		} else {
			entries.push(entryDoc);
		}
	}
	// Collect trailing comments on the object node (before closing brace)
	const trailingComments: Doc[] = [];
	if (node.comments.length > 0) {
		for (const comment of node.comments) {
			trailingComments.push(docText(comment.value));
		}
		node.comments = [];
	}

	// When forced to break, separators must not be wrapped in a group
	// (groups measure independently and would flatten comma+line to comma+space)
	const sep = forceBreak
		? [docText(","), docHardLine()]
		: [docGroup([docText(","), docLine()])];
	const indentChildren: Doc[] = [docLine()];
	for (let i = 0; i < entries.length; i += 1) {
		if (i > 0) {
			for (const s of sep) { indentChildren.push(s); }
		}
		indentChildren.push(entries[i]);
	}
	if (wantsTrailingComma(options, CommaContext.Collection)) {
		indentChildren.push(docIfBreak(docText(","), docNil()));
	}
	// Append trailing comments after entries (on their own lines)
	for (const tc of trailingComments) {
		indentChildren.push(docLine());
		indentChildren.push(tc);
	}

	const inner: Doc[] = [
		docText("{"),
		docIndent(indentChildren),
		docLine(),
		docText("}"),
	];
	if (forceBreak) {
		return docGroupBreak(inner);
	}
	return docGroup(inner);
}

export function printArrayLiteral(node: Node, options: FormatOptions): Doc {
	const d = node.data as ArrayLiteralData;
	if (d.elements.length === 0) return docText("[]");
	const elems: Doc[] = [];
	for (const el of d.elements) {
		elems.push(callPrintNode(el, options));
	}
	const elemParts = docCommaSepList(elems, wantsTrailingComma(options, CommaContext.Collection));
	return docGroup([
		docText("["),
		docIndent(elemParts),
		docSoftLine(),
		docText("]"),
	]);
}

export function printArrowFunction(node: Node, options: FormatOptions): Doc {
	const d = node.data as ArrowFunctionData;
	const isAsync = flagHas(d.arrowFlags, "async") || flagHas(d.arrowFlags, "async_generator");
	const parts: Doc[] = isAsync ? [docText("async ")] : [];
	const params = buildParamList(d.arrowParams, d.arrowParamTypes, d.arrowDefaults, options);
	for (const p of paramListInParens(params, options)) parts.push(p);
	if (d.arrowReturnType !== "") {
		parts.push(docText(": " + d.arrowReturnType));
	}
	parts.push(docText(" => "));
	parts.push(callPrintNode(d.arrowBody, options));
	return docGroup(parts);
}

export function printConditionalExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as ConditionalExprData;
	return docGroup([
		callPrintNode(d.ternaryCondition, options),
		docIndent([
			docLine(),
			docText("? "),
			callPrintNode(d.ternaryConsequent, options),
			docLine(),
			docText(": "),
			callPrintNode(d.ternaryAlternate, options),
		]),
	]);
}

export function printSpreadExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as SpreadExprData;
	return docGroup([docText("..."), callPrintNode(d.spreadArg, options)]);
}

export function printNewExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as NewExprData;
	const args: Doc[] = [];
	for (const arg of d.newArguments) {
		args.push(callPrintNode(arg, options));
	}
	const typeArgs = node.typeArg !== "" ? "<" + node.typeArg + ">" : "";
	const newParts: Doc[] = [docText("new "), printAtom(d.newCallee, options), docText(typeArgs + "(")];
	if (args.length > 0) {
		const argParts = docCommaSepList(args, wantsTrailingComma(options, CommaContext.Params));
		newParts.push(docIndent(argParts));
		newParts.push(docSoftLine());
	}
	newParts.push(docText(")"));
	return docGroup(newParts);
}

export function printTypeAssertion(node: Node, options: FormatOptions): Doc {
	const d = node.data as TypeAssertionData;
	return docGroup([
		printAtom(d.asExpr, options),
		docText(" as " + d.asType),
	]);
}

export function printMatchExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as MatchExprData;
	const cases: Doc[] = [];
	for (const c of d.matchCases) {
		cases.push(printMatchCase(c, options));
	}
	return docGroup([
		docText("match ("),
		callPrintNode(d.matchDisc, options),
		docText(") {"),
		docIndent([docSoftLine(), docJoin(cases, docSoftLine())]),
		docSoftLine(),
		docText("}"),
	]);
}

export function printMatchCase(node: Node, options: FormatOptions): Doc {
	const d = node.data as MatchCaseData;
	const pats: Doc[] = [];
	for (const p of d.casePatterns) {
		pats.push(callPrintNode(p, options));
	}
	const parts: Doc[] = [docJoin(pats, docText(" | "))];
	if (d.caseGuard !== null) {
		parts.push(docText(" when "));
		parts.push(callPrintNode(d.caseGuard, options));
	}
	parts.push(docText(" => "));
	parts.push(callPrintNode(d.caseBody, options));
	parts.push(docText(","));
	return docGroup(parts);
}

export function printTryExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as TryExprData;
	const parts: Doc[] = [docText("try "), callPrintNode(d.tryArg, options)];
	if (d.hasCatch && d.catchVal !== null) {
		parts.push(docText(" catch "));
		parts.push(callPrintNode(d.catchVal, options));
	}
	return docGroup(parts);
}

export function printMoveExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as MoveExprData;
	return docGroup([docText("move "), callPrintNode(d.moveArg, options)]);
}

export function printOutExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as OutExprData;
	return docGroup([docText("out "), printAtom(d.outArg, options)]);
}

export function printAwaitExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as AwaitExprData;
	return docGroup([docText("await "), printAtom(d.awaitArg, options)]);
}

export function printYieldExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as YieldExprData;
	const star = d.isDelegate ? "*" : "";
	return docGroup([docText("yield" + star + " "), printAtom(d.yieldArg, options)]);
}

export function printSizeofExpr(node: Node): Doc {
	const d = node.data as SizeofExprData;
	return docText("sizeof " + d.sizeofType);
}

export function printArrayPattern(node: Node, options: FormatOptions): Doc {
	const d = node.data as ArrayPatternData;
	if (d.patternElements.length === 0) return docText("[]");
	const elements: Doc[] = [];
	for (let i = 0; i < d.patternElements.length; i += 1) {
		if (i > 0) elements.push(docText(", "));
		const isRest = d.hasRestElement && i === d.patternElements.length - 1;
		if (isRest) elements.push(docText("..."));
		elements.push(callPrintNode(d.patternElements[i], options));
	}
	return docGroup([docText("["), docGroup(elements), docText("]")]);
}

export function printObjectPattern(node: Node, options: FormatOptions): Doc {
	const d = node.data as ObjectPatternData;
	if (d.patternProps.length === 0) return docText("{}");
	const props: Doc[] = [];
	for (let i = 0; i < d.patternProps.length; i += 1) {
		if (i > 0) props.push(docText(", "));
		const isRest = d.hasRestProp && i === d.patternProps.length - 1;
		if (isRest) props.push(docText("..."));
		props.push(callPrintNode(d.patternProps[i], options));
	}
	return docGroup([docText("{ "), docGroup(props), docText(" }")]);
}

export function printObjectPatternProp(node: Node, options: FormatOptions): Doc {
	const d = node.data as ObjectPatternPropData;
	// Shorthand `{ x }` when alias is an identifier with the same name.
	if (d.propAlias !== null && d.propAlias.kind === NodeKind.Identifier) {
		const aliasName = (d.propAlias.data as IdentifierData).name;
		if (aliasName === d.propKey) return docText(d.propKey);
	}
	return docGroup([docText(d.propKey + ": "), callPrintNode(d.propAlias, options)]);
}

export function printMacroInvocation(node: Node, options: FormatOptions): Doc {
	const d = node.data as MacroInvocationData;
	const parts: Doc[] = [docText("@" + d.macroName)];
	if (d.macroArgs.length > 0) {
		const args: Doc[] = [];
		for (let i = 0; i < d.macroArgs.length; i += 1) {
			if (i > 0) args.push(docText(", "));
			args.push(callPrintNode(d.macroArgs[i], options));
		}
		parts.push(docText("("));
		parts.push(docGroup(args));
		parts.push(docText(")"));
	}
	return docGroup(parts);
}

export function printFunctionExpr(node: Node, options: FormatOptions): Doc {
	const d = node.data as FunctionExprData;
	// `async`, `generator`, and `async_generator` are encoded in funcExprFlags.
	const isAsync = flagHas(d.funcExprFlags, "async") || flagHas(d.funcExprFlags, "async_generator");
	const isGen = flagHas(d.funcExprFlags, "generator") || flagHas(d.funcExprFlags, "async_generator");
	const head = (isAsync ? "async " : "") + "function" + (isGen ? "*" : "") + " ";
	const parts: Doc[] = [docText(head)];
	// FunctionExprData has no defaults field — pass empty array.
	const noDefaults: Node[] = [];
	const params = buildParamList(d.funcExprParams, d.funcExprParamTypes, noDefaults, options);
	for (const p of paramListInParens(params, options)) parts.push(p);
	if (d.funcExprReturnType !== "") {
		parts.push(docText(": " + d.funcExprReturnType));
	}
	parts.push(docText(" "));
	parts.push(callPrintNode(d.funcExprBody, options));
	return docGroup(parts);
}
