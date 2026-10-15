import { Node, NodeKind, bindSym, define, expansionFile, getImpl, getSize, getTypeImpl, sameType, stringValue } from "std/meta";
import { Pubkey } from "./pubkey";
import { Bytes } from "./bytes";
import {
	accountDiscriminator,
	eventDiscriminator,
	instructionDiscriminator,
	snakeCase,
} from "./discriminator";

export macro anchorIdl(spec: Node): Node {
	const ops = getTypeArg();
	if (ops.kind !== NodeKind.EnumDecl) {
		error("anchorIdl<Op>(spec): Op must be the enum of the program's instructions", ops);
	}
	if (spec.kind !== NodeKind.ObjectLiteral) {
		error("anchorIdl<Op>(spec): spec must be an object literal", spec);
	}
	function nameIndex(names: string[], name: string): int32 {
		let i = 0;
		while (i < names.length) {
			if (names[i] == name) { return i as int32; }
			i = i + 1;
		}
		return -1;
	}

	function unreadableBase(from: Node, base: string, found: Node | null): string {
		if (base.indexOf("<") >= 0) { return "a base with type arguments is not supported; extend a struct that has none"; }
		if (found == null) {
			return "no struct named '" + base + "' is imported where anchorIdl is called; import it there under that name";
		}
		const parent = found!;
		if (parent.kind !== NodeKind.StructDecl && parent.kind !== NodeKind.InterfaceDecl) {
			return "'" + base + "' is not a struct where anchorIdl is called";
		}
		const home = from.resolvedSym!.modulePath;
		const origin = parent.resolvedSym!.modulePath;
		const calledWhereDeclared = home == expansionFile();
		const declaredBesideUnderThatName = origin == home && parent.interfaceName == base;
		if (calledWhereDeclared || declaredBesideUnderThatName) { return ""; }
		return "'" + base + "' names the struct '" + parent.interfaceName + "' of '" + origin +
			"' where anchorIdl is called, which may not be the base '" + from.interfaceName +
			"' was declared with in '" + home + "'; import the '" + base + "' that module declares under that name or, " +
			"when it imports '" + base + "' itself, call anchorIdl there";
	}

	function refuseNamesake(name: string, type: Node, holder: string): void {
		const meant = bindSym(name);
		if (meant == null || sameType(meant, type)) { return; }
		error("anchorIdl: " + holder + ", and where anchorIdl is called '" + name + "' means another type, '" +
			meant!.resolvedSym!.name + "' of '" + meant!.resolvedSym!.modulePath + "'; import the '" + name +
			"' the field was declared with under that name, or call anchorIdl in the module that declares the field", spec);
	}

	function inheritedFirst(from: Node, names: string[], types: string[], decorators: Node[][]): void {
		for (const base of from.interfaceExtends) {
			const parent = getImpl(bindSym(base));
			const unreadable = unreadableBase(from, base, parent);
			if (unreadable != "") {
				error("anchorIdl: '" + from.interfaceName + "' extends '" + base +
					"', whose fields anchorIdl cannot read: " + unreadable, spec);
			}
			inheritedFirst(parent!, names, types, decorators);
		}
		for (let own = 0; own < from.interfaceFields.length; own++) {
			names.push(from.interfaceFields[own]);
			types.push(from.interfaceFieldTypes[own]);
			decorators.push(from.interfaceFieldDecorators[own]);
		}
	}

	function constSeed(bytes: Readonly<Span<uint8>>): string {
		let list = "";
		let i = 0;
		while (i < bytes.length) {
			list = list + (i > 0 ? "," : "") + (bytes[i] as int32);
			i = i + 1;
		}
		return "{\"kind\":\"const\",\"value\":[" + list + "]}";
	}

	function encodesRaw(need: string, written: string): boolean {
		if (need == "u8") { return written == "uint8"; }
		if (need == "le") { return written == "uint16" || written == "uint32" || written == "uint64"; }
		return written == "Pubkey";
	}

	function valueSeed(
		expr: Node, need: string, fields: string[], fieldTypes: string[], held: Node, argNames: string[], argTypes: string[],
	): string {
		if (expr.kind === NodeKind.Identifier) {
			if (need == "key" && nameIndex(fields, expr.name) >= 0) {
				return "{\"kind\":\"account\",\"path\":\"" + snakeCase(expr.name) + "\"}";
			}
			return "";
		}
		if (expr.kind !== NodeKind.MemberExpr || expr.object.kind !== NodeKind.Identifier) { return ""; }
		const base = expr.object.name;
		const owner = nameIndex(fields, base);
		if (owner < 0) {
			const at = nameIndex(argNames, expr.property);
			if (at < 0 || !encodesRaw(need, argTypes[at])) { return ""; }
			return "{\"kind\":\"arg\",\"path\":\"" + snakeCase(expr.property) + "\"}";
		}
		const written = fieldTypes[owner];
		const open = written.indexOf("<");
		const wrapper = open < 0 ? "" : written.slice(0, open);
		if (wrapper != "Owned" && wrapper != "Mutable" && wrapper != "Delegated") { return ""; }
		const dataName = written.slice(open + 1, written.length - 1);
		refuseNamesake(dataName, held.typExprFieldTypes[nameIndex(held.typExprFieldNames, base)].typExprArgs[0],
			"account '" + base + "' holds '" + written + "'");
		const data = getImpl(bindSym(dataName));
		if (data == null) { return ""; }
		const dataFields: string[] = [];
		const dataTypes: string[] = [];
		inheritedFirst(data!, dataFields, dataTypes, []);
		const member = nameIndex(dataFields, expr.property);
		if (member < 0 || !encodesRaw(need, dataTypes[member])) { return ""; }
		return "{\"kind\":\"account\",\"path\":\"" + snakeCase(base) + "." + snakeCase(expr.property) +
			"\",\"account\":\"" + dataName + "\"}";
	}

	function seedJson(seed: Node, fields: string[], fieldTypes: string[], held: Node, argNames: string[], argTypes: string[]): string {
		if (seed.kind === NodeKind.StringLiteral) { return constSeed(stringValue(seed).asBytes()); }
		if (seed.kind === NodeKind.ArrayLiteral) {
			const bytes: uint8[] = [];
			let i = 0;
			while (i < seed.elements.length) {
				const element = seed.elements[i];
				if (element.kind !== NodeKind.NumberLiteral || element.intVal < 0 || element.intVal > 255) {
					if (seed.elements.length == 1) {
						return valueSeed(element, "u8", fields, fieldTypes, held, argNames, argTypes);
					}
					return "";
				}
				bytes.push(element.intVal as uint8);
				i = i + 1;
			}
			return bytes.length == 0 ? "" : constSeed(bytes);
		}
		if (seed.kind === NodeKind.CallExpr) {
			if (seed.callee.kind === NodeKind.Identifier && seed.callee.name == "leBytes" && seed.arguments.length == 1) {
				return valueSeed(seed.arguments[0], "le", fields, fieldTypes, held, argNames, argTypes);
			}
			if (seed.callee.kind === NodeKind.MemberExpr && seed.callee.property == "key" &&
				seed.arguments.length == 0 && seed.callee.object.kind === NodeKind.Identifier) {
				return valueSeed(seed.callee.object, "key", fields, fieldTypes, held, argNames, argTypes);
			}
			return "";
		}
		return valueSeed(seed, "key", fields, fieldTypes, held, argNames, argTypes);
	}

	function pdaJson(decorators: Node[], fields: string[], fieldTypes: string[], held: Node, argNames: string[], argTypes: string[]): string {
		for (const d of decorators) {
			if (d.macroName != "seeds") { continue; }
			let list = "";
			let i = 0;
			while (i < d.macroArgs.length) {
				const one = seedJson(d.macroArgs[i], fields, fieldTypes, held, argNames, argTypes);
				if (one == "") { return ""; }
				list = list + (i > 0 ? "," : "") + one;
				i = i + 1;
			}
			return "{\"seeds\":[" + list + "]}";
		}
		return "";
	}

	function knownProgram(inner: string): string {
		if (inner == "System") { return "11111111111111111111111111111111"; }
		if (inner == "Token") { return "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"; }
		if (inner == "Token2022") { return "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb"; }
		if (inner == "AssociatedToken") { return "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL"; }
		return "";
	}

	function declaredAddress(decorators: Node[], at: Node): string {
		for (const d of decorators) {
			if (d.macroName != "address" || d.macroArgs.length == 0 || d.macroArgs[0].kind !== NodeKind.Identifier) { continue; }
			const name = d.macroArgs[0].name;
			const found = getImpl(bindSym(name));
			if (found == null) {
				error("anchorIdl: @address(" + name + ") names a constant that is not visible where " +
					"anchorIdl is called; import it there", at);
			}
			const init = found!.initializer;
			if (found!.kind === NodeKind.VariableDecl && init.kind === NodeKind.ObjectLiteral &&
				init.keys.length == 1 && init.keys[0] == "bytes" && init.properties[0].kind === NodeKind.ArrayLiteral &&
				init.properties[0].elements.length == 32) {
				let key = Pubkey.zero();
				let n = 0;
				while (n < 32) {
					key.bytes[n] = init.properties[0].elements[n].intVal as uint8;
					n = n + 1;
				}
				return key.toBase58();
			}
		}
		return "";
	}
	let name = "program";
	const declared = define("programId");
	let programAddress = declared;
	let accountTypes: Node[] = [];
	let eventTypes: Node[] = [];
	let errorEnum = "";
	const instructionKeys: string[] = [];
	const instructionTypes: Node[] = [];
	let k = 0;
	while (k < spec.keys.length) {
		const key = spec.keys[k];
		const value = spec.properties[k];
		if (key == "name") { name = stringValue(value); }
		if (key == "address") {
			programAddress = stringValue(value);
			if (declared != "" && programAddress != declared) {
				error("anchorIdl: address '" + programAddress + "' is not the programId '" + declared + "' the build declares", value);
			}
		}
		if (key == "accounts") { accountTypes = value.elements; }
		if (key == "events") { eventTypes = value.elements; }
		if (key == "errors") { errorEnum = value.name; }
		const reserved = key == "name" || key == "address" || key == "accounts" ||
			key == "events" || key == "errors";
		if (!reserved) {
			instructionKeys.push(key);
			instructionTypes.push(value);
		}
		k = k + 1;
	}
	let json = "{\"address\":\"" + programAddress + "\",\"metadata\":{\"name\":\"" + name +
		"\",\"version\":\"0.1.0\",\"spec\":\"0.1.0\",\"description\":\"Created with MetaScript\"}";
	json = json + ",\"instructions\":[";
	let member = 0;
	while (member < ops.enumMembers.length) {
		const op = ops.enumMembers[member];
		let entry = -1;
		let i = 0;
		while (i < instructionKeys.length) {
			if (instructionKeys[i] == op) { entry = i; }
			i = i + 1;
		}
		if (entry < 0) { error("anchorIdl: no accounts entry for instruction '" + op + "'", spec); }
		const pair = instructionTypes[entry].elements;
		const discriminator = instructionDiscriminator(op);
		let tag = "[";
		let b = 0;
		while (b < 8) {
			tag = tag + (b > 0 ? "," : "") + (discriminator.bytes[b] as int32);
			b = b + 1;
		}
		tag = tag + "]";
		if (member > 0) { json = json + ","; }
		json = json + "{\"name\":\"" + snakeCase(op) + "\",\"discriminator\":" + tag +
			",\"accounts\":[";
		let argsDecl: Node | null = null;
		const argNames: string[] = [];
		const argTypes: string[] = [];
		if (pair.length > 1) {
			argsDecl = getTypeImpl(bindSym(pair[1].name));
			if (argsDecl == null || argsDecl!.kind != NodeKind.TypeObject) {
				error("anchorIdl: instruction arguments must be a struct visible where anchorIdl is called", spec);
			}
			let n = 0;
			while (n < argsDecl!.typExprFieldNames.length) {
				const seedType = getTypeImpl(argsDecl!.typExprFieldTypes[n]);
				argNames.push(argsDecl!.typExprFieldNames[n]);
				argTypes.push(seedType != null && seedType!.kind == NodeKind.Identifier ? seedType!.name : "");
				n = n + 1;
			}
		}
		const accountNames: string[] = [];
		const accountWritten: string[] = [];
		const accountDecorators: Node[][] = [];
		let accountsHeld: Node | null = null;
		if (pair.length > 0) {
			const accountsDecl = getImpl(bindSym(pair[0].name))!;
			inheritedFirst(accountsDecl, accountNames, accountWritten, accountDecorators);
			accountsHeld = getTypeImpl(bindSym(pair[0].name))!;
		}
		let f = 0;
		while (f < accountNames.length) {
			const written = accountWritten[f];
			const open = written.indexOf("<");
			const base = open < 0 ? written : written.slice(0, open);
			const inner = open < 0 ? "" : written.slice(open + 1, written.length - 1);
			let account = "{\"name\":\"" + snakeCase(accountNames[f]) + "\"";
			const isWritable = base == "WritableSigner" || base == "Writable" || base == "WritablePda" ||
				base == "Mutable" || base == "ExternalMutable";
			if (isWritable) { account = account + ",\"writable\":true"; }
			if (base == "Signer" || base == "WritableSigner") {
				account = account + ",\"signer\":true";
			}
			const decorators = accountDecorators[f];
			let fixed = declaredAddress(decorators, spec);
			if (fixed == "" && base == "Program") { fixed = knownProgram(inner); }
			if (fixed != "") { account = account + ",\"address\":\"" + fixed + "\""; }
			const pda = pdaJson(decorators, accountNames, accountWritten, accountsHeld!, argNames,
				argTypes);
			if (pda != "") { account = account + ",\"pda\":" + pda; }
			json = json + (f > 0 ? "," : "") + account + "}";
			f = f + 1;
		}
		json = json + "],\"args\":[";
		if (pair.length > 1) {
			let a = 0;
			while (a < argsDecl!.typExprFieldNames.length) {
				const fieldType = getTypeImpl(argsDecl!.typExprFieldTypes[a]);
				if (fieldType == null) {
					error("anchorIdl: unresolved argument field '" + argsDecl!.typExprFieldNames[a] + "'", spec);
				}
				let scalarType = fieldType!;
				let count = -1;
				if (fieldType!.kind == NodeKind.TypeArray && fieldType!.typExprSize >= 0) {
					count = fieldType!.typExprSize as int32;
					scalarType = getTypeImpl(fieldType!.typExprElement)!;
				}
				const written = scalarType.kind == NodeKind.Identifier ? scalarType.name : scalarType.typExprTypeName;
				let idlType = "";
				if (written == "uint8") { idlType = "\"u8\""; }
				if (written == "uint16") { idlType = "\"u16\""; }
				if (written == "uint32") { idlType = "\"u32\""; }
				if (written == "uint64") { idlType = "\"u64\""; }
				if (written == "int8") { idlType = "\"i8\""; }
				if (written == "int16") { idlType = "\"i16\""; }
				if (written == "int32") { idlType = "\"i32\""; }
				if (written == "int64") { idlType = "\"i64\""; }
				if (written == "float32") { idlType = "\"f32\""; }
				if (written == "float64") { idlType = "\"f64\""; }
				if (written == "boolean") { idlType = "\"bool\""; }
				if (sameType(scalarType, bindSym("Pubkey"))) { idlType = "\"pubkey\""; }
				if (sameType(scalarType, bindSym("Bytes"))) { idlType = "\"bytes\""; }
				if (count >= 0 && idlType != "" && written != "Bytes") {
					idlType = "{\"array\":[" + idlType + "," + count + "]}";
				}
				if (count >= 0 && written == "Bytes") { idlType = ""; }
				if (idlType == "") {
					error("anchorIdl: argument type '" + written + "' has no IDL type", spec);
				}
				const argName = snakeCase(argsDecl!.typExprFieldNames[a]);
				json = json + (a > 0 ? "," : "") + "{\"name\":\"" + argName + "\",\"type\":" +
					idlType + "}";
				a = a + 1;
			}
		}
		json = json + "]}";
		member = member + 1;
	}
	json = json + "],\"accounts\":[";
	let t = 0;
	while (t < accountTypes.length) {
		const discriminator = accountDiscriminator(accountTypes[t].name);
		let tag = "[";
		let b = 0;
		while (b < 8) {
			tag = tag + (b > 0 ? "," : "") + (discriminator.bytes[b] as int32);
			b = b + 1;
		}
		json = json + (t > 0 ? "," : "") + "{\"name\":\"" + accountTypes[t].name +
			"\",\"discriminator\":" + tag + "]}";
		t = t + 1;
	}
	json = json + "],\"events\":[";
	let e = 0;
	while (e < eventTypes.length) {
		const discriminator = eventDiscriminator(eventTypes[e].name);
		let tag = "[";
		let b = 0;
		while (b < 8) {
			tag = tag + (b > 0 ? "," : "") + (discriminator.bytes[b] as int32);
			b = b + 1;
		}
		json = json + (e > 0 ? "," : "") + "{\"name\":\"" + eventTypes[e].name +
			"\",\"discriminator\":" + tag + "]}";
		e = e + 1;
	}
	json = json + "],\"errors\":[";
	if (errorEnum != "") {
		const errors = getImpl(bindSym(errorEnum))!;
		for (let r = 0; r < errors.enumMembers.length; r++) {
			const member = errors.enumMembers[r];
			const value = errors.enumValues[r] as int64;
			if (value < 0) {
				error("anchorIdl: error '" + member + "' of '" + errorEnum + "' has the value " + String(value) +
					", and the values of an error enum are zero or more: the program returns the code 6000 plus " +
					"the value, and a code below 6000 is one of the framework's", spec);
			}
			for (let earlier = 0; earlier < r; earlier++) {
				if ((errors.enumValues[earlier] as int64) == value) {
					error("anchorIdl: errors '" + errors.enumMembers[earlier] + "' and '" + member + "' of '" +
						errorEnum + "' have the same value " + String(value) + ", so the program returns the code " +
						String(6000 + value) + " for both and a client cannot tell them apart", spec);
				}
			}
			json = json + (r > 0 ? "," : "") + "{\"code\":" + String(6000 + value) + ",\"name\":\"" +
				member + "\",\"msg\":\"" + member + "\"}";
		}
	}
	json = json + "],\"types\":[";
	const typeNames: string[] = [];
	const typeZeroCopy: boolean[] = [];
	const typeFields: string[][] = [];
	const typeFieldTypes: string[][] = [];
	let a = 0;
	while (a < accountTypes.length) {
		typeNames.push(accountTypes[a].name);
		typeZeroCopy.push(true);
		a = a + 1;
	}
	a = 0;
	while (a < eventTypes.length) {
		typeNames.push(eventTypes[a].name);
		typeZeroCopy.push(false);
		a = a + 1;
	}
	const laidNames: string[] = [];
	const laidSizes: int32[] = [];
	const laidAligns: int32[] = [];
	const laidPacked: int32[] = [];
	let d = 0;
	while (d < typeNames.length) {
		const typeName = typeNames[d];
		const decl = getImpl(bindSym(typeName));
		if (decl == null || decl!.kind == NodeKind.EnumDecl) {
			error("anchorIdl: type '" + typeName + "' must be a struct visible where anchorIdl " +
				"is called; import it there", spec);
		}
		const fields: string[] = [];
		const fieldTypes: string[] = [];
		inheritedFirst(decl!, fields, fieldTypes, []);
		const laidOut = getTypeImpl(bindSym(typeName));
		if (laidOut == null || laidOut!.kind != NodeKind.TypeObject || fields.join(",") != laidOut!.typExprFieldNames.join(",")) {
			error("anchorIdl: type '" + typeName + "' and the structs it extends declare the fields '" +
				fields.join(", ") + "', which are not the fields its type holds", spec);
		}
		typeFields.push(fields);
		typeFieldTypes.push(fieldTypes);
		const zeroCopy = typeZeroCopy[d];
		json = json + (d > 0 ? "," : "") + "{\"name\":\"" + typeName + "\"";
		if (zeroCopy) { json = json + ",\"serialization\":\"bytemuck\",\"repr\":{\"kind\":\"c\"}"; }
		json = json + ",\"type\":{\"kind\":\"struct\",\"fields\":[";
		let f = 0;
		while (f < fields.length) {
			const written = fieldTypes[f];
			const open = written.indexOf("[");
			const element = open < 0 ? written : written.slice(0, open);
			let count = "";
			if (open >= 0) {
				count = written.slice(open + 1, written.length - 1);
				if (count == "" || element.indexOf("[") >= 0) {
					error("anchorIdl: field '" + fields[f] + "' of '" + typeName + "' has type '" +
						written + "'; an account or event field array must be one T[N]", spec);
				}
			}
			const held = laidOut!.typExprFieldTypes[f];
			const one = held.kind == NodeKind.TypeArray ? held.typExprElement : held;
			const holder = "field '" + fields[f] + "' of '" + typeName + "' has type '" + written + "'";
			let idlType = "";
			if (element == "uint8") { idlType = "\"u8\""; }
			if (element == "uint16") { idlType = "\"u16\""; }
			if (element == "uint32") { idlType = "\"u32\""; }
			if (element == "uint64") { idlType = "\"u64\""; }
			if (element == "int8") { idlType = "\"i8\""; }
			if (element == "int16") { idlType = "\"i16\""; }
			if (element == "int32") { idlType = "\"i32\""; }
			if (element == "int64") { idlType = "\"i64\""; }
			if (element == "float32") { idlType = "\"f32\""; }
			if (element == "float64") { idlType = "\"f64\""; }
			if (element == "boolean") { idlType = "\"bool\""; }
			if (element == "Pubkey") { idlType = "\"pubkey\""; }
			if (element.startsWith("BitSet<") && element.endsWith(">")) {
				refuseNamesake(element.slice(7, element.length - 1), one.typExprArgs[0], holder);
				const members = getImpl(bindSym(element.slice(7, element.length - 1)));
				if (members == null || members!.kind != NodeKind.EnumDecl) {
					error("anchorIdl: field '" + fields[f] + "' of '" + typeName + "' is a BitSet " +
						"of an enum that is not visible where anchorIdl is called; import it there", spec);
				}
				const memberCount = members!.enumMembers.length;
				idlType = "{\"array\":[\"u8\"," + ((memberCount + 7) / 8) + "]}";
				if (memberCount <= 64) { idlType = "\"u64\""; }
				if (memberCount <= 32) { idlType = "\"u32\""; }
				if (memberCount <= 16) { idlType = "\"u16\""; }
				if (memberCount <= 8) { idlType = "\"u8\""; }
			}
			if (idlType == "") {
				refuseNamesake(element, one, holder);
				const named = getImpl(bindSym(element));
				if (named != null && named!.kind == NodeKind.EnumDecl) {
					const width = getSize(bindSym(element)!);
					idlType = width == 1 ? "\"u8\"" : width == 2 ? "\"u16\"" : "\"i32\"";
				}
			}
			if (idlType == "") {
				const nested = getImpl(bindSym(element));
				if (nested == null) {
					error("anchorIdl: field '" + fields[f] + "' of '" + typeName + "' has type '" +
						written + "', which has no IDL type: use sized integers, boolean, Pubkey, " +
						"an enum, T[N] or a struct imported where anchorIdl is called", spec);
				}
				idlType = "{\"defined\":{\"name\":\"" + element + "\"}}";
				let known = false;
				let n = 0;
				while (n < typeNames.length) {
					if (typeNames[n] == element) { known = true; }
					n = n + 1;
				}
				if (!known) {
					typeNames.push(element);
					typeZeroCopy.push(zeroCopy);
				}
			}
			if (count != "") { idlType = "{\"array\":[" + idlType + "," + count + "]}"; }
			json = json + (f > 0 ? "," : "") + "{\"name\":\"" + snakeCase(fields[f]) +
				"\",\"type\":" + idlType + "}";
			f = f + 1;
		}
		json = json + "]}}";
		d = d + 1;
	}
	let progress = true;
	while (progress) {
		progress = false;
		let l = 0;
		while (l < typeNames.length) {
			let done = false;
			let m = 0;
			while (m < laidNames.length) {
				if (laidNames[m] == typeNames[l]) { done = true; }
				m = m + 1;
			}
			const fields = typeFields[l];
			let offset = 0;
			let structAlign = 1;
			let ready = !done;
			let f = 0;
			while (ready && f < fields.length) {
				const written = typeFieldTypes[l][f];
				const open = written.indexOf("[");
				const element = open < 0 ? written : written.slice(0, open);
				const count = open < 0 ? 1 : written.slice(open + 1, written.length - 1).parseInt();
				let size = 0;
				let align = 1;
				if (element == "uint8" || element == "int8" || element == "boolean") { size = 1; }
				if (element == "uint16" || element == "int16") { size = 2; align = 2; }
				if (element == "uint32" || element == "int32") { size = 4; align = 4; }
				if (element == "uint64" || element == "int64") { size = 8; align = 8; }
				if (element == "float32") { size = 4; align = 4; }
				if (element == "float64") { size = 8; align = 8; }
				if (element == "Pubkey") { size = 32; }
				if (element.startsWith("BitSet<") && element.endsWith(">")) {
					const members = getImpl(bindSym(element.slice(7, element.length - 1)))!;
					const memberCount = members.enumMembers.length;
					size = (memberCount + 7) / 8;
					if (memberCount <= 64) { size = 8; align = 8; }
					if (memberCount <= 32) { size = 4; align = 4; }
					if (memberCount <= 16) { size = 2; align = 2; }
					if (memberCount <= 8) { size = 1; align = 1; }
				}
				if (size == 0) {
					const named = getImpl(bindSym(element));
					if (named != null && named!.kind == NodeKind.EnumDecl) {
						size = getSize(bindSym(element)!);
						align = size;
					}
				}
				let packed = 0;
				if (size == 0) {
					let n = 0;
					while (n < laidNames.length) {
						if (laidNames[n] == element) {
							size = laidSizes[n];
							align = laidAligns[n];
							packed = laidPacked[n];
						}
						n = n + 1;
					}
					if (size != 0 && packed != size && typeZeroCopy[l]) {
						error("anchorIdl: '" + element + "' ends with " + (size - packed) +
							" byte(s) of C padding, which sit between the fields of '" +
							typeNames[l] + "' at '" + fields[f] + "'; Anchor's " +
							"zero-copy (bytemuck Pod) has none: add an explicit padding field " +
							"to '" + element + "'", spec);
					}
				}
				if (size == 0) {
					ready = false;
				} else {
					const aligned = (offset + align - 1) / align * align;
					if (aligned != offset && typeZeroCopy[l]) {
						error("anchorIdl: '" + typeNames[l] + "' has " + (aligned - offset) +
							" byte(s) of C padding before field '" + fields[f] +
							"'; Anchor's zero-copy (bytemuck Pod) has none and its clients read " +
							"the fields back to back: order the fields by alignment or add an " +
							"explicit padding field", spec);
					}
					offset = aligned + size * (count as int32);
					if (align > structAlign) { structAlign = align; }
				}
				f = f + 1;
			}
			if (ready) {
				laidNames.push(typeNames[l]);
				laidSizes.push((offset + structAlign - 1) / structAlign * structAlign);
				laidAligns.push(structAlign);
				laidPacked.push(offset);
				progress = true;
			}
			l = l + 1;
		}
	}
	json = json + "]}";
	return { kind: NodeKind.StringLiteral, line: spec.line, column: spec.column, value: json };
}
