// Assignment-like layout: how the left side, the operator and the right side of a declarator,
// an assignment, an object property or a class property share a line.

import {
	Node, NodeKind, BinaryExprData, UnaryExprData, AwaitExprData, YieldExprData, ConditionalExprData,
	ArrowFunctionData, ObjectLiteralData, ArrayLiteralData, ObjectPatternData, ObjectPatternPropData,
	TypeAssertionData, CallExprData, IdentifierData,
} from "../../../ast/node";
import { isAssignOp } from "../../../ast/operators";
import { FormatOptions } from "../options";
import { Doc, docText, docGroup, docGroupWithId, docIndent, docLine, docIndentIfGroupBreaks, newGroupId } from "../doc";
import { rawTemplateAt } from "./literals";
import { isPoorlyBreakableMemberOrCallChain } from "./calls";

export enum AssignmentLayout {
	OnlyLeft,
	Fluid,
	BreakAfterOperator,
	NeverBreakAfterOperator,
	BreakLeftHandSide,
	Chain,
	ChainTail,
	ChainTailArrowChain,
}

export type AssignmentShape = {
	leftIsShort: boolean,
	breakLeftHandSide: boolean,
	inChain: boolean,
};

export function plainShape(): AssignmentShape {
	return { leftIsShort: false, breakLeftHandSide: false, inChain: false };
}

const minOverlapForBreak = 3;

export function isShortKey(keyWidth: int32, options: FormatOptions): boolean {
	return keyWidth < options.tabWidth + minOverlapForBreak;
}

function isTemplate(node: Node, options: FormatOptions): boolean {
	return (node.kind == NodeKind.StringLiteral || node.kind == NodeKind.BinaryExpr) && rawTemplateAt(node, options) != "";
}

function isAssignment(node: Node): boolean {
	return node.kind == NodeKind.BinaryExpr && isAssignOp((node.data as BinaryExprData).operator);
}

function isBinaryLike(node: Node, options: FormatOptions): boolean {
	return node.kind == NodeKind.BinaryExpr && !isAssignment(node) && !isTemplate(node, options);
}

function isLiteral(node: Node, options: FormatOptions): boolean {
	return match (node.kind) {
		NodeKind.NumberLiteral | NodeKind.BooleanLiteral | NodeKind.NullLiteral | NodeKind.BigIntLiteral | NodeKind.RegexLiteral => true,
		NodeKind.StringLiteral => !isTemplate(node, options),
		_ => false,
	};
}

function isNonNull(node: Node): boolean {
	return node.kind == NodeKind.TypeAssertion && (node.data as TypeAssertionData).asType == "!";
}

function shouldInlineLogical(node: Node): boolean {
	const d = node.data as BinaryExprData;
	if (d.operator != "&&" && d.operator != "||" && d.operator != "??") return false;
	const right = d.right;
	if (right.kind == NodeKind.ObjectLiteral) return (right.data as ObjectLiteralData).properties.length > 0;
	if (right.kind == NodeKind.ArrayLiteral) return (right.data as ArrayLiteralData).elements.length > 0;
	return right.kind == NodeKind.JSXElement || right.kind == NodeKind.JSXFragment;
}

function lastNonUnaryArgument(node: Node): Node {
	let argument = (node.data as UnaryExprData).operand;
	while (argument.kind == NodeKind.UnaryExpr) argument = (argument.data as UnaryExprData).operand;
	return argument;
}

function awaitedOrYielded(node: Node): Node | null {
	if (node.kind == NodeKind.AwaitExpr) return (node.data as AwaitExprData).awaitArg;
	if (node.kind == NodeKind.YieldExpr) return (node.data as YieldExprData).yieldArg;
	return null;
}

function shouldBreakAfterOperator(right: Node, options: FormatOptions): boolean {
	if (isTemplate(right, options)) return false;
	if (isAssignment(right)) return isAssignment((right.data as BinaryExprData).right);
	if (isBinaryLike(right, options)) return !shouldInlineLogical(right);
	if (right.kind == NodeKind.ConditionalExpr) {
		const test = (right.data as ConditionalExprData).ternaryCondition;
		return isBinaryLike(test, options) && !shouldInlineLogical(test);
	}
	if (right.kind == NodeKind.ClassDecl) return false;
	let argument: Node | null = null;
	if (right.kind == NodeKind.AwaitExpr || right.kind == NodeKind.YieldExpr) {
		argument = awaitedOrYielded(right);
	} else if (right.kind == NodeKind.UnaryExpr) {
		const last = lastNonUnaryArgument(right);
		const inner = awaitedOrYielded(last);
		argument = inner != null ? inner : last;
	}
	if (argument == null) return false;
	return isLiteral(argument, options) || isPoorlyBreakableMemberOrCallChain(argument, options);
}

function isRequireCall(node: Node): boolean {
	if (node.kind != NodeKind.CallExpr) return false;
	const callee = (node.data as CallExprData).callee;
	return callee.kind == NodeKind.Identifier && (callee.data as IdentifierData).name == "require";
}

function chainLayout(right: Node): AssignmentLayout {
	if (isAssignment(right)) return AssignmentLayout.Chain;
	if (right.kind == NodeKind.ArrowFunction && (right.data as ArrowFunctionData).arrowBody.kind == NodeKind.ArrowFunction) {
		return AssignmentLayout.ChainTailArrowChain;
	}
	return AssignmentLayout.ChainTail;
}

export function assignmentLayout(shape: AssignmentShape, right: Node | null, options: FormatOptions): AssignmentLayout {
	if (right == null) return AssignmentLayout.OnlyLeft;
	if (shape.inChain) return chainLayout(right);
	if (isRequireCall(right)) return AssignmentLayout.NeverBreakAfterOperator;
	if (shape.breakLeftHandSide) return AssignmentLayout.BreakLeftHandSide;
	if (shouldBreakAfterOperator(right, options)) return AssignmentLayout.BreakAfterOperator;
	if (shape.leftIsShort) return AssignmentLayout.NeverBreakAfterOperator;
	let unwrapped = right;
	while (true) {
		if (unwrapped.kind == NodeKind.UnaryExpr) {
			unwrapped = (unwrapped.data as UnaryExprData).operand;
		} else if (isNonNull(unwrapped)) {
			unwrapped = (unwrapped.data as TypeAssertionData).asExpr;
		} else {
			break;
		}
	}
	if (unwrapped.kind == NodeKind.StringLiteral && !isTemplate(unwrapped, options)) return AssignmentLayout.BreakAfterOperator;
	if (isPoorlyBreakableMemberOrCallChain(unwrapped, options)) return AssignmentLayout.BreakAfterOperator;
	if (unwrapped.kind == NodeKind.ClassDecl || unwrapped.kind == NodeKind.NumberLiteral || unwrapped.kind == NodeKind.BooleanLiteral || isTemplate(unwrapped, options)) {
		return AssignmentLayout.NeverBreakAfterOperator;
	}
	return AssignmentLayout.Fluid;
}

// `operator` carries its own leading space (" =") or none (":").
export function printAssignmentLike(left: Doc, operator: string, right: Node | null, rightDoc: Doc, shape: AssignmentShape, options: FormatOptions): Doc {
	return assembleAssignment(left, operator, assignmentLayout(shape, right, options), rightDoc);
}

export function assembleAssignment(left: Doc, operator: string, layout: AssignmentLayout, rightDoc: Doc): Doc {
	if (layout == AssignmentLayout.OnlyLeft) return left;
	const leftDoc = layout == AssignmentLayout.BreakLeftHandSide ? left : docGroup([left]);
	const head: Doc[] = [leftDoc, docText(operator)];
	if (layout == AssignmentLayout.Chain) return docGroup([...head, docLine(), rightDoc]);
	if (layout == AssignmentLayout.ChainTail) return docGroup([...head, docIndent([docLine(), rightDoc])]);
	if (layout == AssignmentLayout.Fluid) return docGroup([...head, ...fluidTail(rightDoc)]);
	if (layout == AssignmentLayout.BreakAfterOperator) return docGroup([...head, docGroup([docIndent([docLine(), rightDoc])])]);
	if (layout == AssignmentLayout.NeverBreakAfterOperator || layout == AssignmentLayout.ChainTailArrowChain) return docGroup([...head, docText(" "), rightDoc]);
	if (layout == AssignmentLayout.BreakLeftHandSide) return docGroup([...head, docText(" "), docGroup([rightDoc])]);
	throw new Error("internal: assignment layout without a tail");
}

function fluidTail(rightDoc: Doc): Doc[] {
	const id = newGroupId();
	return [docGroupWithId([docIndent([docLine()])], id), docIndentIfGroupBreaks([rightDoc], id)];
}

function isIdentChar(c: int32): boolean {
	return (c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || (c >= "0".code && c <= "9".code) || c == "_".code || c == "$".code || c == ".".code;
}

function isOpenBracket(c: int32): boolean {
	return c == "<".code || c == "(".code || c == "[".code || c == "{".code;
}

function isCloseBracket(c: int32, previous: int32): boolean {
	return (c == ">".code && previous != "=".code) || c == ")".code || c == "]".code || c == "}".code;
}

// The top-level comma-separated items of a type argument or parameter list written as text.
function topLevelItems(inner: string): string[] {
	const items: string[] = [];
	let depth = 0;
	let start = 0;
	let previous = 0;
	for (let i = 0; i < inner.byteLength; i += 1) {
		const c = inner.byteAt(i);
		if (isOpenBracket(c)) depth += 1;
		else if (isCloseBracket(c, previous)) depth -= 1;
		else if (c == ",".code && depth == 0) {
			items.push(inner.byteSlice(start, i).trim());
			start = i + 1;
		}
		previous = c;
	}
	const last = inner.byteSlice(start, inner.byteLength).trim();
	if (last != "") items.push(last);
	return items;
}

// The type arguments of a type written as `Name<A, B>`, or null when it is not a generic reference.
function referenceTypeArguments(type: string): string[] | null {
	const text = type.trim();
	let open = 0;
	while (open < text.byteLength && isIdentChar(text.byteAt(open))) open += 1;
	if (open == 0 || open >= text.byteLength || text.byteAt(open) != "<".code) return null;
	if (text.byteAt(text.byteLength - 1) != ">".code) return null;
	let depth = 0;
	let previous = 0;
	for (let i = open; i < text.byteLength; i += 1) {
		const c = text.byteAt(i);
		if (isOpenBracket(c)) depth += 1;
		else if (isCloseBracket(c, previous)) depth -= 1;
		if (depth == 0 && i < text.byteLength - 1) return null;
		previous = c;
	}
	return topLevelItems(text.byteSlice(open + 1, text.byteLength - 1));
}

function isConditionalType(type: string): boolean {
	return type.includes(" extends ") && type.includes(" ? ");
}

export function isComplexTypeAnnotation(type: string): boolean {
	const args = referenceTypeArguments(type);
	if (args == null || args.length <= 1) return false;
	for (const arg of args) {
		if (isConditionalType(arg)) return true;
		const inner = referenceTypeArguments(arg);
		if (inner != null && inner.length > 0) return true;
	}
	return false;
}

export function isBreakableTypeAnnotation(type: string): boolean {
	const args = referenceTypeArguments(type);
	return args != null && args.length > 0;
}

// `generics` is the written list including its angle brackets, or "".
export function isComplexTypeAliasGenerics(generics: string): boolean {
	if (generics.byteLength < 2) return false;
	const items = topLevelItems(generics.byteSlice(1, generics.byteLength - 1));
	if (items.length <= 1) return false;
	for (const item of items) {
		if (item.includes(" extends ") || item.includes("=")) return true;
	}
	return false;
}

export function isComplexObjectPattern(pattern: Node): boolean {
	const props = (pattern.data as ObjectPatternData).patternProps;
	if (props.length <= 2) return false;
	for (const prop of props) {
		if (prop.kind != NodeKind.ObjectPatternProp) continue;
		const d = prop.data as ObjectPatternPropData;
		const shorthand = d.propAlias != null && d.propAlias.kind == NodeKind.Identifier && (d.propAlias.data as IdentifierData).name == d.propKey;
		if (!shorthand || d.propDefault != null) return true;
	}
	return false;
}

// A type text the reference cannot break anywhere: only name characters, so a long one moves below the operator.
export function isUnbreakableTypeText(type: string): boolean {
	if (type == "") return false;
	for (let i = 0; i < type.byteLength; i += 1) {
		if (!isIdentChar(type.byteAt(i))) return false;
	}
	return true;
}
