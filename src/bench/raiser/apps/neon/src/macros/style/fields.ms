import { Node, NodeKind, DeclKind, NodeFlag, stringValue } from "std/meta";

@comptime export function styleTable(): string[][] {
	return [
		["direction",           "Direction",         "word", "enum",   "ignore"],
		["flexDirection",       "FlexDirection",     "word", "enum",   "ignore"],
		["justifyContent",      "Justify",           "word", "enum",   "ignore"],
		["alignItems",          "Align",             "word", "enum",   "ignore"],
		["alignSelf",           "Align",             "word", "enum",   "ignore"],
		["alignContent",        "Align",             "word", "enum",   "ignore"],
		["position",            "PositionType",      "word", "position", "ignore"],
		["flexWrap",            "Wrap",              "word", "enum",   "ignore"],
		["display",             "Display",           "word", "display", "ignore"],
		["flex",                "number",            "num",  "num",    "ignore"],
		["flexGrow",            "number",            "num",  "num",    "ignore"],
		["flexShrink",          "number",            "num",  "num",    "ignore"],
		["flexBasis",           "number | string",   "len",  "dim",    "ignore"],
		["width",               "number | string",   "len",  "dim",    "ignore"],
		["height",              "number | string",   "len",  "dim",    "ignore"],
		["minWidth",            "number | string",   "len",  "dim",    "ignore"],
		["minHeight",           "number | string",   "len",  "dim",    "ignore"],
		["maxWidth",            "number | string",   "len",  "dim",    "ignore"],
		["maxHeight",           "number | string",   "len",  "dim",    "ignore"],
		["aspectRatio",         "number",            "num",  "num",    "ignore"],
		["margin",              "number | string",   "len",  "dim",    "ignore"],
		["marginHorizontal",    "number | string",   "len", "dim",    "ignore"],
		["marginVertical",      "number | string",   "len", "dim",    "ignore"],
		["marginTop",           "number | string",   "len",  "dim",    "ignore"],
		["marginBottom",        "number | string",   "len",  "dim",    "ignore"],
		["marginLeft",          "number | string",   "len",  "dim",    "ignore"],
		["marginRight",         "number | string",   "len",  "dim",    "ignore"],
		["marginStart",         "number | string",   "len", "ignore", "ignore"],
		["marginEnd",           "number | string",   "len", "ignore", "ignore"],
		["padding",             "number | string",   "len",  "dim",    "ignore"],
		["paddingHorizontal",   "number | string",   "len", "dim",    "ignore"],
		["paddingVertical",     "number | string",   "len", "dim",    "ignore"],
		["paddingTop",          "number | string",   "len",  "dim",    "ignore"],
		["paddingBottom",       "number | string",   "len",  "dim",    "ignore"],
		["paddingLeft",         "number | string",   "len",  "dim",    "ignore"],
		["paddingRight",        "number | string",   "len",  "dim",    "ignore"],
		["paddingStart",        "number | string",   "len", "ignore", "ignore"],
		["paddingEnd",          "number | string",   "len", "ignore", "ignore"],
		["inset",               "number | string",   "len", "ignore", "ignore"],
		["top",                 "number | string",   "len",  "dim",    "ignore"],
		["left",                "number | string",   "len",  "dim",    "ignore"],
		["right",               "number | string",   "len",  "dim",    "ignore"],
		["bottom",              "number | string",   "len",  "dim",    "ignore"],
		["start",               "number | string",   "len", "ignore", "ignore"],
		["end",                 "number | string",   "len", "ignore", "ignore"],
		["gap",                 "number | string",   "len",  "dim",    "ignore"],
		["rowGap",              "number | string",   "len",  "dim",    "ignore"],
		["columnGap",           "number | string",   "len",  "dim",    "ignore"],
		["backgroundColor",     "string",            "word", "paint",  "paint"],
		["backgroundImage",     "string",            "word", "ignore", "ignore"],
		["backgroundSize",      "string",            "word", "ignore", "ignore"],
		["backgroundPosition",  "string",            "word", "ignore", "ignore"],
		["backgroundRepeat",    "string",            "word", "ignore", "ignore"],
		["borderWidth",         "number",            "len",  "num",    "ignore"],
		["borderTopWidth",      "number",            "len", "ignore", "ignore"],
		["borderRightWidth",    "number",            "len", "ignore", "ignore"],
		["borderBottomWidth",   "number",            "len", "ignore", "ignore"],
		["borderLeftWidth",     "number",            "len", "ignore", "ignore"],
		["borderStartWidth",    "number",            "len", "ignore", "ignore"],
		["borderEndWidth",      "number",            "len", "ignore", "ignore"],
		["borderColor",         "string",            "word", "paint",  "ignore"],
		["borderTopColor",      "string",            "word", "ignore", "ignore"],
		["borderRightColor",    "string",            "word", "ignore", "ignore"],
		["borderBottomColor",   "string",            "word", "ignore", "ignore"],
		["borderLeftColor",     "string",            "word", "ignore", "ignore"],
		["borderStartColor",    "string",            "word", "ignore", "ignore"],
		["borderEndColor",      "string",            "word", "ignore", "ignore"],
		["borderRadius",        "number",            "len",  "paint",  "ignore"],
		["borderTopLeftRadius", "number",            "len", "ignore", "ignore"],
		["borderTopRightRadius", "number",            "len", "ignore", "ignore"],
		["borderBottomRightRadius", "number",            "len", "ignore", "ignore"],
		["borderBottomLeftRadius", "number",            "len", "ignore", "ignore"],
		["borderTopStartRadius", "number",            "len", "ignore", "ignore"],
		["borderTopEndRadius",  "number",            "len", "ignore", "ignore"],
		["borderBottomStartRadius", "number",            "len", "ignore", "ignore"],
		["borderBottomEndRadius", "number",            "len", "ignore", "ignore"],
		["borderStyle",         "BorderStyle",       "word", "ignore", "ignore"],
		["outlineWidth",        "number",            "len", "ignore", "ignore"],
		["outlineColor",        "string",            "word", "ignore", "ignore"],
		["outlineStyle",        "BorderStyle",       "word", "ignore", "ignore"],
		["outlineOffset",       "number",            "len", "ignore", "ignore"],
		["boxSizing",           "BoxSizing",         "word", "ignore", "ignore"],
		["opacity",             "number",            "num",  "paint",  "paint"],
		["color",               "string",            "word", "paint",  "paint"],
		["fontSize",            "number",            "len",  "paint",  "ignore"],
		["fontWeight",          "FontWeight",        "word", "paint",  "paint"],
		["letterSpacing",       "number",            "len",  "ignore", "ignore"],
		["lineHeight",          "number",            "len",  "ignore", "ignore"],
		["textAlign",           "TextAlign",         "word", "ignore", "ignore"],
		["textTransform",       "TextTransform",     "word", "ignore", "ignore"],
		["whiteSpace",          "WhiteSpace",        "word", "ignore", "ignore"],
		["writingDirection",    "WritingDirection",  "word", "ignore", "ignore"],
		["overflow",            "Overflow",          "word", "overflow", "ignore"],
		["overflowX",           "Overflow",          "word", "ignore", "ignore"],
		["overflowY",           "Overflow",          "word", "ignore", "ignore"],
		["zIndex",              "number",            "num",  "paint",  "ignore"],
		["fontFamily",          "string",            "word", "paint",  "ignore"],
		["fontSizeAdjust",      "FontSizeAdjust",    "word", "paint",  "ignore"],
		["transform",           "string",            "word", "ignore", "ignore"],
		["transformOrigin",     "string",            "word", "ignore", "ignore"],
		["cursor",              "string",            "word", "ignore", "ignore"],
		["boxShadow",           "string",            "word", "paint",  "ignore"],
		["clipPath",            "string",            "word", "ignore", "ignore"],
		["transition",          "string",            "word", "ignore", "ignore"],
		["filter",              "string",            "word", "ignore", "ignore"],
		["backdropFilter",      "string",            "word", "ignore", "ignore"],
		["mixBlendMode",        "string",            "word", "ignore", "ignore"],
		["isolation",           "Isolation",         "word", "ignore", "ignore"],
		["backfaceVisibility",  "BackfaceVisibility", "word", "ignore", "ignore"],
		["pointerEvents",       "string",            "word", "ignore", "ignore"],
		["userSelect",          "UserSelect",        "word", "ignore", "ignore"],
		["fontStyle",           "FontStyle",         "word", "paint",  "paint"],
		["textDecorationLine",  "TextDecorationLine", "word", "paint",  "paint"],
		["textDecorationStyle", "TextDecorationStyle", "word", "paint", "ignore"],
		["textDecorationColor", "string",            "word", "paint",  "ignore"],
		["textDecorationThickness", "number | string",   "len", "ignore", "ignore"],
		["textUnderlineOffset", "number | string",   "len", "ignore", "ignore"],
		["objectFit",           "ObjectFit",         "word", "ignore", "ignore"],
		["listStyleType",       "string",            "word", "ignore", "ignore"],
		["borderCollapse",      "BorderCollapse",    "word", "ignore", "ignore"],
		["borderSpacing",       "number | string",   "len", "ignore", "ignore"],
	];
}

@comptime export function cssProperty(field: string): string {
	return match (field) {
		"writingDirection" => "direction",
		"marginHorizontal" => "marginInline",
		"marginVertical" => "marginBlock",
		"marginStart" => "marginInlineStart",
		"marginEnd" => "marginInlineEnd",
		"paddingHorizontal" => "paddingInline",
		"paddingVertical" => "paddingBlock",
		"paddingStart" => "paddingInlineStart",
		"paddingEnd" => "paddingInlineEnd",
		"start" => "insetInlineStart",
		"end" => "insetInlineEnd",
		"borderStartWidth" => "borderInlineStartWidth",
		"borderEndWidth" => "borderInlineEndWidth",
		"borderStartColor" => "borderInlineStartColor",
		"borderEndColor" => "borderInlineEndColor",
		"borderTopStartRadius" => "borderStartStartRadius",
		"borderTopEndRadius" => "borderStartEndRadius",
		"borderBottomStartRadius" => "borderEndStartRadius",
		"borderBottomEndRadius" => "borderEndEndRadius",
		_ => field,
	};
}

@comptime export function styleClassFields(): string[][] {
	return [
		["cssId", "string"],
		["css",   "string"],
		["media", "StyleBlock[]"],
	];
}

const COL_TYPE = 1;
const COL_BROWSER = 2;
const COL_VOID = 3;
const COL_TERMINAL = 4;

export macro applyCssPropBody(node: Node): Node {
	const table = styleTable();
	const L = node.line;
	const C = node.column;
	const cases: Node[] = [];
	for (let i = 0; i < table.length; i = i + 1) {
		const row = table[i];
		if (row.length !== 5) { error("style table row " + row[0] + " must carry a type and every host", node); }
		const fieldName = row[0];
		const proj = row[COL_BROWSER];
		if (proj !== "word" && proj !== "num" && proj !== "len") { error("browser projection for " + fieldName + " must be word, num or len", node); }
		const arg: Node = { kind: NodeKind.Identifier, line: L, column: C, name: "v" };
		cases.push({
			kind: NodeKind.MatchCase, line: L, column: C,
			casePatterns: [{ kind: NodeKind.StringLiteral, line: L, column: C, value: fieldName }],
			caseGuard: null,
			caseBody: {
				kind: NodeKind.BlockStmt, line: L, column: C,
				statements: [{
					kind: NodeKind.ExprStmt, line: L, column: C,
					expr: {
						kind: NodeKind.BinaryExpr, line: L, column: C, operator: "=",
						left: {
							kind: NodeKind.MemberExpr, line: L, column: C,
							object: { kind: NodeKind.Identifier, line: L, column: C, name: "css" },
							property: cssProperty(fieldName), isOptional: false,
						},
						right: {
							kind: NodeKind.CallExpr, line: L, column: C,
							callee: { kind: NodeKind.Identifier, line: L, column: C, name: proj },
							arguments: [arg], isDirectCall: false, resolvedOverloadIdx: -1,
						},
					},
				}],
			},
		});
	}
	cases.push({
		kind: NodeKind.MatchCase, line: L, column: C,
		casePatterns: [{ kind: NodeKind.Identifier, line: L, column: C, name: "_" }],
		caseGuard: null,
		caseBody: {
			kind: NodeKind.BlockStmt, line: L, column: C,
			statements: [{
				kind: NodeKind.ThrowStmt, line: L, column: C,
				throwArg: {
					kind: NodeKind.NewExpr, line: L, column: C,
					newCallee: { kind: NodeKind.Identifier, line: L, column: C, name: "Error" },
					newArguments: [{
						kind: NodeKind.BinaryExpr, line: L, column: C, operator: "+",
						left: { kind: NodeKind.StringLiteral, line: L, column: C, value: "no browser projection for style field " },
						right: { kind: NodeKind.Identifier, line: L, column: C, name: "name" },
					}],
				},
			}],
		},
	});
	return {
		kind: NodeKind.SpliceMany, line: L, column: C,
		spliceNodes: [{
			kind: NodeKind.ExportDecl, line: L, column: C,
			exportedDecl: {
				kind: NodeKind.FunctionDecl, line: L, column: C,
				fnName: "applyCssProp",
				params: ["css", "name", "v"],
				fnParamTypes: ["CssStyle", "string", "StyleValue"],
				fnBody: {
					kind: NodeKind.BlockStmt, line: L, column: C,
					statements: [{
						kind: NodeKind.MatchStmt, line: L, column: C,
						matchStmtDisc: { kind: NodeKind.Identifier, line: L, column: C, name: "name" },
						matchStmtCases: cases,
					}],
				},
				fnFlags: "", fnReturnType: "void", fnDefaults: [], nativeName: "",
				nameLocation: { line: L, column: C },
			},
		}],
	};
}

export macro applyCssBody(node: Node): Node {
	const table = styleTable();
	const L = node.line;
	const C = node.column;
	const stmts: Node[] = [{
		kind: NodeKind.ExprStmt, line: L, column: C,
		expr: {
			kind: NodeKind.BinaryExpr, line: L, column: C, operator: "=",
			left: {
				kind: NodeKind.MemberExpr, line: L, column: C,
				object: { kind: NodeKind.Identifier, line: L, column: C, name: "css" },
				property: "cssText", isOptional: false,
			},
			right: { kind: NodeKind.StringLiteral, line: L, column: C, value: "" },
		},
	}];
	for (let i = 0; i < table.length; i = i + 1) {
		const fieldName = table[i][0];
		const read: Node = {
			kind: NodeKind.MemberExpr, line: L, column: C,
			object: { kind: NodeKind.Identifier, line: L, column: C, name: "s" },
			property: fieldName, isOptional: false,
		};
		stmts.push({
			kind: NodeKind.IfStmt, line: L, column: C,
			condition: {
				kind: NodeKind.BinaryExpr, line: L, column: C, operator: "!==",
				left: read,
				right: { kind: NodeKind.NullLiteral, line: L, column: C },
			},
			consequent: {
				kind: NodeKind.BlockStmt, line: L, column: C,
				statements: [{
					kind: NodeKind.ExprStmt, line: L, column: C,
					expr: {
						kind: NodeKind.CallExpr, line: L, column: C,
						callee: { kind: NodeKind.Identifier, line: L, column: C, name: "applyCssProp" },
						arguments: [
							{ kind: NodeKind.Identifier, line: L, column: C, name: "css" },
							{ kind: NodeKind.StringLiteral, line: L, column: C, value: fieldName },
							{
								kind: NodeKind.TypeAssertion, line: L, column: C, asType: "StyleValue",
								asExpr: read,
							},
						],
						isDirectCall: false, resolvedOverloadIdx: -1,
					},
				}],
			},
			alternate: { kind: NodeKind.BlockStmt, line: L, column: C, statements: [] },
		});
	}
	return {
		kind: NodeKind.SpliceMany, line: L, column: C,
		spliceNodes: [{
			kind: NodeKind.ExportDecl, line: L, column: C,
			exportedDecl: {
				kind: NodeKind.FunctionDecl, line: L, column: C,
				fnName: "applyCss",
				params: ["css", "s"],
				fnParamTypes: ["CssStyle", "Style"],
				fnBody: { kind: NodeKind.BlockStmt, line: L, column: C, statements: stmts },
				fnFlags: "", fnReturnType: "void", fnDefaults: [], nativeName: "",
				nameLocation: { line: L, column: C },
			},
		}],
	};
}

export macro asFlexStyleBody(node: Node): Node {
	const table = styleTable();
	const L = node.line;
	const C = node.column;
	const stmts: Node[] = [{
		kind: NodeKind.VariableDecl, line: L, column: C,
		declName: "st", declType: "FlexStyle", declKind: DeclKind.Const,
		initializer: { kind: NodeKind.ObjectLiteral, line: L, column: C, properties: [], keys: [], keyLocations: [] },
	}];
	for (let i = 0; i < table.length; i = i + 1) {
		const row = table[i];
		if (row.length !== 5) { error("style table row " + row[0] + " must carry a type and every host", node); }
		const fieldName = row[0];
		const how = row[COL_VOID];
		if (how === "paint" || how === "ignore") { continue; }
		if (how !== "enum" && how !== "num" && how !== "dim" && how !== "position" && how !== "display" && how !== "overflow") { error("void projection for " + fieldName + " must be enum, num, dim, position, display, overflow, paint or ignore", node); }
		const read: Node = {
			kind: NodeKind.MemberExpr, line: L, column: C,
			object: { kind: NodeKind.Identifier, line: L, column: C, name: "s" },
			property: fieldName, isOptional: false,
		};
		const value: Node = how === "enum" ? read : {
			kind: NodeKind.CallExpr, line: L, column: C,
			callee: { kind: NodeKind.Identifier, line: L, column: C, name: how },
			arguments: [read],
			isDirectCall: false, resolvedOverloadIdx: -1,
		};
		// Null-guard every projection: an unset Style field must stay UNSET on
		// the FlexStyle, never become a boxed null. applyStyle (yoga/src/style.ms)
		// reads `field !== null`; a boxed null passes that check and reaches the
		// setter as garbage — on the C backend a style whose maxWidth arrived
		// boxed-null clamped every node to 0x0 (found by the ios-host arc's
		// walk probe; applyCssBody below has guarded the same way from the
		// start).
		stmts.push({
			kind: NodeKind.IfStmt, line: L, column: C,
			condition: {
				kind: NodeKind.BinaryExpr, line: L, column: C, operator: "!==",
				left: read,
				right: { kind: NodeKind.NullLiteral, line: L, column: C },
			},
			consequent: {
				kind: NodeKind.BlockStmt, line: L, column: C,
				statements: [{
					kind: NodeKind.ExprStmt, line: L, column: C,
					expr: {
						kind: NodeKind.BinaryExpr, line: L, column: C, operator: "=",
						left: {
							kind: NodeKind.MemberExpr, line: L, column: C,
							object: { kind: NodeKind.Identifier, line: L, column: C, name: "st" },
							property: fieldName, isOptional: false,
						},
						right: value,
					},
				}],
			},
			alternate: { kind: NodeKind.BlockStmt, line: L, column: C, statements: [] },
		});
	}
	stmts.push({
		kind: NodeKind.ReturnStmt, line: L, column: C,
		argument: { kind: NodeKind.Identifier, line: L, column: C, name: "st" },
	});
	return {
		kind: NodeKind.SpliceMany, line: L, column: C,
		spliceNodes: [{
			kind: NodeKind.ExportDecl, line: L, column: C,
			exportedDecl: {
				kind: NodeKind.FunctionDecl, line: L, column: C,
				fnName: "asFlexStyle",
				params: ["s"],
				fnParamTypes: ["Style"],
				fnBody: { kind: NodeKind.BlockStmt, line: L, column: C, statements: stmts },
				fnFlags: "", fnReturnType: "FlexStyle", fnDefaults: [], nativeName: "",
				nameLocation: { line: L, column: C },
			},
		}],
	};
}

export macro terminalStyleCoverage(node: Node): Node {
	const table = styleTable();
	for (let i = 0; i < table.length; i = i + 1) {
		const row = table[i];
		if (row.length !== 5) { error("style table row " + row[0] + " must carry a type and every host", node); }
		const how = row[COL_TERMINAL];
		if (how !== "paint" && how !== "ignore") { error("terminal projection for " + row[0] + " must be paint or ignore", node); }
	}
	return { kind: NodeKind.SpliceMany, line: node.line, column: node.column, spliceNodes: [] };
}

export macro styleInterfaceBody(node: Node): Node {
	const table = styleTable();
	const block = node.kind === NodeKind.StringLiteral && stringValue(node) === "block";
	if (!block && node.kind === NodeKind.StringLiteral) { error("styleInterfaceBody takes 0 for Style or \"block\" for StyleBlock", node); }
	const classFields = block ? [] : styleClassFields();
	const L = node.line;
	const C = node.column;
	const names: string[] = block ? ["fromWidth"] : [];
	const types: string[] = block ? ["number"] : [];
	for (let i = 0; i < table.length; i = i + 1) {
		const row = table[i];
		if (row.length !== 5) { error("style table row " + row[0] + " must carry a type and every host", node); }
		names.push(row[0]);
		types.push(row[COL_TYPE] + " | null");
	}
	for (let i = 0; i < classFields.length; i = i + 1) {
		names.push(classFields[i][0]);
		types.push(classFields[i][1] + " | null");
	}
	return {
		kind: NodeKind.SpliceMany, line: L, column: C,
		spliceNodes: [{
			kind: NodeKind.ExportDecl, line: L, column: C,
			exportedDecl: {
				kind: NodeKind.InterfaceDecl, line: L, column: C,
				interfaceName: block ? "StyleBlock" : "Style", interfaceFields: names, interfaceFieldTypes: types, interfaceExtends: [],
				nameLocation: { line: L, column: C },
			},
		}],
	};
}

export macro setStyleFieldBody(node: Node): Node {
	const table = styleTable();
	const L = node.line;
	const C = node.column;
	const cases: Node[] = [];
	for (let i = 0; i < table.length; i = i + 1) {
		const row = table[i];
		if (row.length !== 5) { error("style table row " + row[0] + " must carry a type and every host", node); }
		const fieldName = row[0];
		cases.push({
			kind: NodeKind.MatchCase, line: L, column: C,
			casePatterns: [{ kind: NodeKind.StringLiteral, line: L, column: C, value: fieldName }],
			caseGuard: null,
			caseBody: {
				kind: NodeKind.BlockStmt, line: L, column: C,
				statements: [{
					kind: NodeKind.ExprStmt, line: L, column: C,
					expr: {
						kind: NodeKind.BinaryExpr, line: L, column: C, operator: "=",
						left: { kind: NodeKind.MemberExpr, line: L, column: C, object: { kind: NodeKind.Identifier, line: L, column: C, name: "s" }, property: fieldName, isOptional: false },
						right: {
							kind: NodeKind.TypeAssertion, line: L, column: C,
							asExpr: { kind: NodeKind.Identifier, line: L, column: C, name: "v" },
							asType: row[COL_TYPE] + " | null",
						},
					},
				}],
			},
		});
	}
	cases.push({
		kind: NodeKind.MatchCase, line: L, column: C,
		casePatterns: [{ kind: NodeKind.Identifier, line: L, column: C, name: "_" }],
		caseGuard: null,
		caseBody: {
			kind: NodeKind.BlockStmt, line: L, column: C,
			statements: [{
				kind: NodeKind.ThrowStmt, line: L, column: C,
				throwArg: {
					kind: NodeKind.NewExpr, line: L, column: C,
					newCallee: { kind: NodeKind.Identifier, line: L, column: C, name: "Error" },
					newArguments: [{
						kind: NodeKind.BinaryExpr, line: L, column: C, operator: "+",
						left: { kind: NodeKind.StringLiteral, line: L, column: C, value: "no Style field named " },
						right: { kind: NodeKind.Identifier, line: L, column: C, name: "name" },
					}],
				},
			}],
		},
	});
	return {
		kind: NodeKind.SpliceMany, line: L, column: C,
		spliceNodes: [{
			kind: NodeKind.ExportDecl, line: L, column: C,
			exportedDecl: {
				kind: NodeKind.FunctionDecl, line: L, column: C,
				fnName: "setStyleField", params: ["s", "name", "v"], fnParamTypes: ["Style", "string", "StyleValue"],
				fnBody: { kind: NodeKind.BlockStmt, line: L, column: C, statements: [{
			kind: NodeKind.MatchStmt, line: L, column: C,
			matchStmtDisc: { kind: NodeKind.Identifier, line: L, column: C, name: "name" },
			matchStmtCases: cases,
		}] },
				fnFlags: "", fnReturnType: "void", fnDefaults: [], nativeName: "",
				nameLocation: { line: L, column: C },
			},
		}],
	};
}

export macro mergeStyleBody(node: Node): Node {
	const table = styleTable();
	const variant = node.kind === NodeKind.StringLiteral ? stringValue(node) : "style";
	if (variant !== "style" && variant !== "block" && variant !== "mask") { error("mergeStyleBody takes 0, \"block\" or \"mask\"", node); }
	const L = node.line;
	const C = node.column;
	const props: Node[] = [];
	const keys: string[] = [];
	for (let i = 0; i < table.length; i = i + 1) {
		const row = table[i];
		if (row.length !== 5) { error("style table row " + row[0] + " must carry a type and every host", node); }
		const fieldName = row[0];
		keys.push(fieldName);
		props.push({
			kind: NodeKind.ConditionalExpr, line: L, column: C,
			ternaryCondition: {
				kind: NodeKind.BinaryExpr, line: L, column: C, operator: "!==",
				left: { kind: NodeKind.MemberExpr, line: L, column: C, object: { kind: NodeKind.Identifier, line: L, column: C, name: "over" }, property: fieldName, isOptional: false },
				right: { kind: NodeKind.NullLiteral, line: L, column: C },
			},
			ternaryConsequent: { kind: NodeKind.MemberExpr, line: L, column: C, object: { kind: NodeKind.Identifier, line: L, column: C, name: "over" }, property: fieldName, isOptional: false },
			ternaryAlternate: { kind: NodeKind.MemberExpr, line: L, column: C, object: { kind: NodeKind.Identifier, line: L, column: C, name: "base" }, property: fieldName, isOptional: false },
		});
	}
	if (variant === "style") {
		keys.push("media");
		props.push({
			kind: NodeKind.CallExpr, line: L, column: C,
			callee: { kind: NodeKind.Identifier, line: L, column: C, name: "mergeMedia" },
			arguments: [
				{ kind: NodeKind.Identifier, line: L, column: C, name: "base" },
				{ kind: NodeKind.Identifier, line: L, column: C, name: "over" },
			],
		});
	}
	if (variant === "mask") {
		keys.push("fromWidth");
		props.push({ kind: NodeKind.MemberExpr, line: L, column: C, object: { kind: NodeKind.Identifier, line: L, column: C, name: "base" }, property: "fromWidth", isOptional: false });
	}
	const fnName = variant === "style" ? "mergeStyle" : variant === "block" ? "mergeBlock" : "maskBlock";
	const baseType = variant === "mask" ? "StyleBlock" : "Style";
	const overType = variant === "block" ? "StyleBlock" : "Style";
	const resultType = variant === "mask" ? "StyleBlock" : "Style";
	return {
		kind: NodeKind.SpliceMany, line: L, column: C,
		spliceNodes: [{
			kind: NodeKind.ExportDecl, line: L, column: C,
			exportedDecl: {
				kind: NodeKind.FunctionDecl, line: L, column: C,
				fnName: fnName, params: ["base", "over"], fnParamTypes: [baseType, overType],
				fnBody: { kind: NodeKind.BlockStmt, line: L, column: C, statements: [{
			kind: NodeKind.ReturnStmt, line: L, column: C,
			argument: { kind: NodeKind.ObjectLiteral, line: L, column: C, properties: props, keys: keys, keyLocations: [] },
		}] },
				fnFlags: "", fnReturnType: resultType, fnDefaults: [], nativeName: "",
				nameLocation: { line: L, column: C },
			},
		}],
	};
}

export macro styleToCssBody(node: Node): Node {
	const table = styleTable();
	const L = node.line;
	const C = node.column;
	const stmts: Node[] = [{
		kind: NodeKind.VariableDecl, line: L, column: C,
		declName: "out", declType: "string", declKind: DeclKind.Let,
		initializer: { kind: NodeKind.StringLiteral, line: L, column: C, value: "" },
	}];
	for (let i = 0; i < table.length; i = i + 1) {
		const row = table[i];
		if (row.length !== 5) { error("style table row " + row[0] + " must carry a type and every host", node); }
		const fieldName = row[0];
		const ty = row[COL_TYPE];
		const proj = row[COL_BROWSER];
		let emitter = "";
		if (proj === "word") { emitter = "cssWord"; }
		else if (proj === "num") { emitter = "cssRatio"; }
		else if (proj === "len" && ty === "number") { emitter = "cssPx"; }
		else if (proj === "len" && ty === "number | string") { emitter = "cssLen"; }
		else { error("no CSS emitter for " + fieldName + " (" + proj + " / " + ty + ")", node); }
		const read: Node = { kind: NodeKind.MemberExpr, line: L, column: C, object: { kind: NodeKind.Identifier, line: L, column: C, name: "s" }, property: fieldName, isOptional: false };
		const arg: Node = proj === "word" ? { kind: NodeKind.TypeAssertion, line: L, column: C, asExpr: read, asType: "string | null" } : read;
		stmts.push({
			kind: NodeKind.ExprStmt, line: L, column: C,
			expr: {
				kind: NodeKind.BinaryExpr, line: L, column: C, operator: "=",
				left: { kind: NodeKind.Identifier, line: L, column: C, name: "out" },
				right: {
					kind: NodeKind.BinaryExpr, line: L, column: C, operator: "+",
					left: { kind: NodeKind.Identifier, line: L, column: C, name: "out" },
					right: {
						kind: NodeKind.CallExpr, line: L, column: C,
						callee: { kind: NodeKind.Identifier, line: L, column: C, name: emitter },
						arguments: [{ kind: NodeKind.StringLiteral, line: L, column: C, value: cssProperty(fieldName) }, arg],
						isDirectCall: false, resolvedOverloadIdx: -1,
					},
				},
			},
		});
	}
	stmts.push({ kind: NodeKind.ReturnStmt, line: L, column: C, argument: { kind: NodeKind.Identifier, line: L, column: C, name: "out" } });
	return {
		kind: NodeKind.SpliceMany, line: L, column: C,
		spliceNodes: [{
			kind: NodeKind.ExportDecl, line: L, column: C,
			exportedDecl: {
				kind: NodeKind.FunctionDecl, line: L, column: C,
				fnName: "styleToCss", params: ["s"], fnParamTypes: ["Style"],
				fnBody: { kind: NodeKind.BlockStmt, line: L, column: C, statements: stmts },
				fnFlags: "", fnReturnType: "string", fnDefaults: [], nativeName: "",
				nameLocation: { line: L, column: C },
			},
		}],
	};
}

export macro cssStyleExternBody(node: Node): Node {
	const table = styleTable();
	const L = node.line;
	const C = node.column;
	const body: Node[] = [];
	for (let i = 0; i < table.length; i = i + 1) {
		const row = table[i];
		if (row.length !== 5) { error("style table row " + row[0] + " must carry a type and every host", node); }
		body.push({ kind: NodeKind.PropertyDecl, line: L, column: C, propName: cssProperty(row[0]), propType: "string", propIsStatic: false, propIsReadonly: false, propVisibility: "", propInitializer: null as unknown as Node });
	}
	body.push({ kind: NodeKind.PropertyDecl, line: L, column: C, propName: "cssText", propType: "string", propIsStatic: false, propIsReadonly: false, propVisibility: "", propInitializer: null as unknown as Node });
	const cls: Node = { kind: NodeKind.ClassDecl, line: L, column: C, className: "CssStyle", classExtends: "", classBody: body, nameLocation: { line: L, column: C } };
	cls.flags = cls.flags.incl(NodeFlag.ExternC);
	return { kind: NodeKind.SpliceMany, line: L, column: C, spliceNodes: [{ kind: NodeKind.ExportDecl, line: L, column: C, exportedDecl: cls }] };
}
