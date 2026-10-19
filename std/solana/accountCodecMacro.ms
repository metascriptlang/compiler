import { Node, NodeKind, bindSym, createNodeAt, getAlign, resolveType } from "std/meta";
import { AccountLayout, accountLayout } from "./accountLayout";
import { accountEnumBits, accountReadSigned, accountReadUnsigned, accountValueFromBits, accountWriteUnsigned } from "./accountCodecScalars";
import { accountFloat32Bits, accountFloat32FromBits, accountFloat64Bits, accountFloat64FromBits } from "./accountCodecKernel";

struct CodecReadSymbols {
	unsigned: Node;
	signed: Node;
	fromBits: Node;
	float32: Node;
	float64: Node;
}

struct CodecWriteSymbols {
	unsigned: Node;
	enumBits: Node;
	float32: Node;
	float64: Node;
}

function wireLayout(type: Node): AccountLayout {
	const wide = resolveType("uint64");
	const real = resolveType("float64");
	if (wide == null || real == null || getAlign(wide) != 8 || getAlign(real) != 8) {
		throw new Error("SOLANA_ACCOUNT_CODEC_ABI: this target's native 64-bit alignment differs from the SBF account wire ABI");
	}
	const layout = accountLayout(type);
	if (layout.size > 2147483639) { throw new Error("SOLANA_ACCOUNT_CODEC_SIZE: account plus discriminator exceeds the byte array size limit"); }
	return layout;
}

function integer(value: int64, at: Node): Node {
	return createNodeAt(NodeKind.NumberLiteral, {
		value: value as number, isFloat: false, intVal: value as int64,
		outOfRangeText: "", isBitPattern: false,
	}, at.location);
}

function boolean(value: boolean, at: Node): Node {
	return createNodeAt(NodeKind.BooleanLiteral, { boolValue: value }, at.location);
}

function binary(operator: string, left: Node, right: Node): Node {
	return createNodeAt(NodeKind.BinaryExpr, { operator: operator, left: left, right: right }, left.location);
}

function cast(value: Node, type: string): Node {
	return createNodeAt(NodeKind.TypeAssertion, { asExpr: value, asType: type }, value.location);
}

function call(symbol: Node, arguments: Node[], at: Node): Node {
	return createNodeAt(NodeKind.CallExpr, {
		callee: symbol, arguments: arguments, isDirectCall: false, resolvedOverloadIdx: -1,
	}, at.location);
}

function member(value: Node, name: string): Node {
	return createNodeAt(NodeKind.MemberExpr, { object: value, property: name, isOptional: false }, value.location);
}

function index(value: Node, at: int32): Node {
	return createNodeAt(NodeKind.ArrayAccess, { array: value, index: integer(at, value) }, value.location);
}

function word(bytes: Node, offset: int32, width: int32, reader: Node): Node {
	return call(reader, [bytes, integer(offset, bytes), integer(width, bytes)], bytes);
}

function enumMemberValid(layout: AccountLayout, value: Node, raw: boolean): Node {
	const patterns: Node[] = [];
	const seen: int64[] = [];
	for (const ordinal of layout.values) {
		const expected = raw ? int64Bits(accountEnumBits(ordinal, layout.size)) : ordinal as int64;
		let duplicate = false;
		for (const prior of seen) { if (prior == expected) { duplicate = true; break; } }
		if (duplicate) { continue; }
		seen.push(expected);
		patterns.push(integer(expected, value));
	}
	const accepted: Node = createNodeAt(NodeKind.MatchCase, {
		casePatterns: patterns, caseGuard: null as unknown as Node, caseBody: boolean(true, value),
	}, value.location);
	const wildcard: Node = createNodeAt(NodeKind.Identifier, { name: "_" }, value.location);
	const refused: Node = createNodeAt(NodeKind.MatchCase, {
		casePatterns: [wildcard], caseGuard: null as unknown as Node, caseBody: boolean(false, value),
	}, value.location);
	return createNodeAt(NodeKind.MatchExpr, { matchDisc: value, matchCases: [accepted, refused] }, value.location);
}

function fieldsValid(layout: AccountLayout, bytes: Node, offset: int32, reader: Node): Node {
	if (layout.kind == "boolean") { return binary("<=", word(bytes, offset, layout.size, reader), cast(integer(1, bytes), "uint64")); }
	if (layout.kind == "enum") { return enumMemberValid(layout, word(bytes, offset, layout.size, reader), true); }
	if (layout.kind == "distinct") { return fieldsValid(layout.children[0], bytes, offset, reader); }
	let valid = boolean(true, bytes);
	if (layout.kind == "struct") {
		for (let i = 0; i < layout.children.length; i += 1) {
			valid = binary("&&", valid, fieldsValid(layout.children[i], bytes, offset + layout.offsets[i], reader));
		}
	} else if (layout.kind == "array") {
		for (let i = 0; i < layout.count; i += 1) {
			valid = binary("&&", valid, fieldsValid(layout.children[0], bytes, offset + i * layout.children[0].size, reader));
		}
	}
	return valid;
}

function valueValid(layout: AccountLayout, value: Node): Node {
	if (layout.kind == "enum") { return enumMemberValid(layout, cast(value, "int32"), false); }
	if (layout.kind == "distinct") {
		let base = layout.children[0];
		while (base.kind == "distinct") { base = base.children[0]; }
		if (base.kind == "enum") { return enumMemberValid(base, cast(value, "int32"), false); }
		return boolean(true, value);
	}
	let valid = boolean(true, value);
	if (layout.kind == "struct") {
		for (let i = 0; i < layout.children.length; i += 1) {
			valid = binary("&&", valid, valueValid(layout.children[i], member(value, layout.names[i])));
		}
	} else if (layout.kind == "array") {
		for (let i = 0; i < layout.count; i += 1) {
			valid = binary("&&", valid, valueValid(layout.children[0], index(value, i)));
		}
	}
	return valid;
}

function unsignedType(size: int32): string {
	return match (size) { 1 => "uint8", 2 => "uint16", 4 => "uint32", _ => "uint64" };
}

function scalar(layout: AccountLayout, bytes: Node, offset: int32, symbols: CodecReadSymbols): Node {
	if (layout.kind == "boolean") { return binary("!=", word(bytes, offset, layout.size, symbols.unsigned), cast(integer(0, bytes), "uint64")); }
	if (layout.kind == "float32") { return call(symbols.float32, [cast(word(bytes, offset, 4, symbols.unsigned), "uint32")], bytes); }
	if (layout.kind == "float64" || layout.kind == "number") { return call(symbols.float64, [word(bytes, offset, 8, symbols.unsigned)], bytes); }
	if (layout.kind == "enum") {
		let signed = false;
		for (const value of layout.values) { if (value < 0) { signed = true; } }
		const bits = signed
			? call(symbols.signed, [bytes, integer(offset, bytes), integer(layout.size, bytes)], bytes)
			: word(bytes, offset, layout.size, symbols.unsigned);
		return cast(bits, "int32");
	}
	if (layout.kind == "bitset") {
		if (layout.size <= 8) { return cast(word(bytes, offset, layout.size, symbols.unsigned), unsignedType(layout.size)); }
		const elements: Node[] = [];
		for (let i = 0; i < layout.size; i += 1) { elements.push(cast(word(bytes, offset + i, 1, symbols.unsigned), "uint8")); }
		const array: Node = createNodeAt(NodeKind.ArrayLiteral, { elements: elements }, bytes.location);
		return cast(array, "uint8[" + layout.size + "]");
	}
	if (layout.kind == "int8" || layout.kind == "int16" || layout.kind == "int32" || layout.kind == "int64") {
		return cast(call(symbols.signed, [bytes, integer(offset, bytes), integer(layout.size, bytes)], bytes), layout.kind);
	}
	return cast(word(bytes, offset, layout.size, symbols.unsigned), layout.kind);
}

function readValue(layout: AccountLayout, bytes: Node, offset: int32, symbols: CodecReadSymbols): Node {
	if (layout.kind == "struct") {
		const properties: Node[] = [];
		for (let i = 0; i < layout.children.length; i += 1) {
			properties.push(readValue(layout.children[i], bytes, offset + layout.offsets[i], symbols));
		}
		const object: Node = createNodeAt(NodeKind.ObjectLiteral, { keys: layout.names, properties: properties, keyLocations: [] }, bytes.location);
		return object;
	}
	if (layout.kind == "array") {
		const elements: Node[] = [];
		for (let i = 0; i < layout.count; i += 1) { elements.push(readValue(layout.children[0], bytes, offset + i * layout.children[0].size, symbols)); }
		const array: Node = createNodeAt(NodeKind.ArrayLiteral, { elements: elements }, bytes.location);
		return array;
	}
	if (layout.kind == "distinct") {
		let base = layout.children[0];
		while (base.kind == "distinct") { base = base.children[0]; }
		return call(symbols.fromBits, [scalar(base, bytes, offset, symbols)], bytes);
	}
	const value = scalar(layout, bytes, offset, symbols);
	return layout.kind == "enum" || layout.kind == "bitset" ? call(symbols.fromBits, [value], bytes) : value;
}

function writeValue(layout: AccountLayout, bytes: Node, value: Node, offset: int32, statements: Node[], symbols: CodecWriteSymbols): void {
	if (layout.kind == "struct") {
		for (let i = 0; i < layout.children.length; i += 1) {
			writeValue(layout.children[i], bytes, member(value, layout.names[i]), offset + layout.offsets[i], statements, symbols);
		}
		return;
	}
	if (layout.kind == "array") {
		for (let i = 0; i < layout.count; i += 1) {
			writeValue(layout.children[0], bytes, index(value, i), offset + i * layout.children[0].size, statements, symbols);
		}
		return;
	}
	if (layout.kind == "distinct") { writeValue(layout.children[0], bytes, value, offset, statements, symbols); return; }
	if (layout.kind == "bitset" && layout.size > 8) {
		const storage = cast(value, "uint8[" + layout.size + "]");
		for (let i = 0; i < layout.size; i += 1) {
			const write = call(symbols.unsigned, [bytes, integer(offset + i, bytes), integer(1, bytes), cast(index(storage, i), "uint64")], bytes);
			statements.push(createNodeAt(NodeKind.ExprStmt, { expr: write }, bytes.location));
		}
		return;
	}
	let bits: Node;
	if (layout.kind == "boolean") {
		bits = cast(createNodeAt(NodeKind.ConditionalExpr, {
			ternaryCondition: value, ternaryConsequent: integer(1, value), ternaryAlternate: integer(0, value),
		}, value.location), "uint64");
	} else if (layout.kind == "enum") {
		bits = call(symbols.enumBits, [cast(value, "int32"), integer(layout.size, value)], value);
	} else if (layout.kind == "float32") {
		bits = cast(call(symbols.float32, [cast(value, "float32")], value), "uint64");
	} else if (layout.kind == "float64" || layout.kind == "number") {
		bits = call(symbols.float64, [cast(value, "float64")], value);
	} else {
		bits = cast(value, "uint64");
	}
	const write = call(symbols.unsigned, [bytes, integer(offset, bytes), integer(layout.size, bytes), bits], bytes);
	statements.push(createNodeAt(NodeKind.ExprStmt, { expr: write }, bytes.location));
}

function layoutText(layout: AccountLayout): string {
	if (layout.kind == "distinct") { return layoutText(layout.children[0]); }
	if (layout.kind == "struct") {
		let fields = "";
		for (let i = 0; i < layout.children.length; i += 1) {
			fields += (i > 0 ? "," : "") + "[\"" + layout.names[i] + "\"," + layout.offsets[i] + "," + layoutText(layout.children[i]) + "]";
		}
		return "{\"k\":\"struct\",\"z\":" + layout.size + ",\"f\":[" + fields + "]}";
	}
	if (layout.kind == "array") {
		return "{\"k\":\"array\",\"z\":" + layout.size + ",\"n\":" + layout.count + ",\"e\":" + layoutText(layout.children[0]) + "}";
	}
	let signed = false;
	if (layout.kind == "enum") { for (const value of layout.values) { if (value < 0) { signed = true; } } }
	return "{\"k\":\"" + layout.kind + "\",\"z\":" + layout.size + (signed ? ",\"s\":1" : "") + "}";
}

export macro accountLayoutText(): Node {
	const type = getTypeArg();
	return createNodeAt(NodeKind.StringLiteral, { value: layoutText(wireLayout(type)) }, type.location);
}

export macro accountCodecSize(): Node {
	const type = getTypeArg();
	return integer(wireLayout(type).size + 8, type);
}

export macro accountCodecFieldsValid(bytes: Node): Node {
	return fieldsValid(wireLayout(getTypeArg()), bytes, 8, bindSym("accountReadUnsigned")!);
}

export macro accountCodecValueValid(value: Node): Node {
	return valueValid(wireLayout(getTypeArg()), value);
}

export macro accountCodecRead(bytes: Node): Node {
	const symbols: CodecReadSymbols = {
		unsigned: bindSym("accountReadUnsigned")!,
		signed: bindSym("accountReadSigned")!,
		fromBits: bindSym("accountValueFromBits")!,
		float32: bindSym("accountFloat32FromBits")!,
		float64: bindSym("accountFloat64FromBits")!,
	};
	return readValue(wireLayout(getTypeArg()), bytes, 8, symbols);
}

export macro accountCodecWrite(bytes: Node, value: Node): Node {
	const statements: Node[] = [];
	const symbols: CodecWriteSymbols = {
		unsigned: bindSym("accountWriteUnsigned")!,
		enumBits: bindSym("accountEnumBits")!,
		float32: bindSym("accountFloat32Bits")!,
		float64: bindSym("accountFloat64Bits")!,
	};
	writeValue(wireLayout(getTypeArg()), bytes, value, 8, statements, symbols);
	return createNodeAt(NodeKind.SpliceMany, { spliceNodes: statements }, bytes.location);
}
