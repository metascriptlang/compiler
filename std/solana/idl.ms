import { Node, NodeKind, bindSym, getImpl, stringValue } from "std/meta";
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
	let name = "program";
	let programAddress = "";
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
		if (key == "address") { programAddress = stringValue(value); }
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
		const accountsDecl = getImpl(bindSym(pair[0].name))!;
		let f = 0;
		while (f < accountsDecl.interfaceFields.length) {
			const written = accountsDecl.interfaceFieldTypes[f];
			const open = written.indexOf("<");
			const base = open < 0 ? written : written.slice(0, open);
			const inner = open < 0 ? "" : written.slice(open + 1, written.length - 1);
			let account = "{\"name\":\"" + snakeCase(accountsDecl.interfaceFields[f]) + "\"";
			const isWritable = base == "WritableSigner" || base == "Writable" ||
				base == "Mutable" || base == "ExternalMutable";
			if (isWritable) { account = account + ",\"writable\":true"; }
			if (base == "Signer" || base == "WritableSigner") {
				account = account + ",\"signer\":true";
			}
			if (base == "Program" && inner == "System") {
				account = account + ",\"address\":\"11111111111111111111111111111111\"";
			}
			if (base == "Program" && inner == "Token") {
				account = account + ",\"address\":\"TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA\"";
			}
			if (base == "Program" && inner == "AssociatedToken") {
				account = account + ",\"address\":\"ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL\"";
			}
			json = json + (f > 0 ? "," : "") + account + "}";
			f = f + 1;
		}
		json = json + "],\"args\":[";
		if (pair.length > 1) {
			const argsDecl = getImpl(bindSym(pair[1].name))!;
			let a = 0;
			while (a < argsDecl.interfaceFields.length) {
				const written = argsDecl.interfaceFieldTypes[a];
				let idlType = "";
				if (written == "uint8") { idlType = "\"u8\""; }
				if (written == "uint16") { idlType = "\"u16\""; }
				if (written == "uint32") { idlType = "\"u32\""; }
				if (written == "uint64") { idlType = "\"u64\""; }
				if (written == "int8") { idlType = "\"i8\""; }
				if (written == "int16") { idlType = "\"i16\""; }
				if (written == "int32") { idlType = "\"i32\""; }
				if (written == "int64") { idlType = "\"i64\""; }
				if (written == "boolean") { idlType = "\"bool\""; }
				if (written == "Pubkey") { idlType = "\"pubkey\""; }
				if (written == "Bytes") { idlType = "\"bytes\""; }
				if (idlType == "") {
					error("anchorIdl: argument type '" + written + "' has no IDL type", spec);
				}
				const argName = snakeCase(argsDecl.interfaceFields[a]);
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
		let r = 0;
		while (r < errors.enumMembers.length) {
			json = json + (r > 0 ? "," : "") + "{\"code\":" + (6000 + r) + ",\"name\":\"" +
				errors.enumMembers[r] + "\",\"msg\":\"" + errors.enumMembers[r] + "\"}";
			r = r + 1;
		}
	}
	json = json + "],\"types\":[";
	const typeNames: string[] = [];
	const typeZeroCopy: boolean[] = [];
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
		const fields = decl!.interfaceFields;
		const fieldTypes = decl!.interfaceFieldTypes;
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
			let idlType = "";
			if (element == "uint8") { idlType = "\"u8\""; }
			if (element == "uint16") { idlType = "\"u16\""; }
			if (element == "uint32") { idlType = "\"u32\""; }
			if (element == "uint64") { idlType = "\"u64\""; }
			if (element == "int8") { idlType = "\"i8\""; }
			if (element == "int16") { idlType = "\"i16\""; }
			if (element == "int32") { idlType = "\"i32\""; }
			if (element == "int64") { idlType = "\"i64\""; }
			if (element == "boolean") { idlType = "\"bool\""; }
			if (element == "Pubkey") { idlType = "\"pubkey\""; }
			if (idlType == "") {
				const nested = getImpl(bindSym(element));
				if (nested == null || nested!.kind == NodeKind.EnumDecl) {
					error("anchorIdl: field '" + fields[f] + "' of '" + typeName + "' has type '" +
						written + "', which has no IDL type: use sized integers, boolean, Pubkey, " +
						"T[N] or a struct imported where anchorIdl is called (an enum is stored " +
						"as uint8)", spec);
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
			const decl = getImpl(bindSym(typeNames[l]))!;
			let offset = 0;
			let structAlign = 1;
			let ready = !done;
			let f = 0;
			while (ready && f < decl.interfaceFields.length) {
				const written = decl.interfaceFieldTypes[f];
				const open = written.indexOf("[");
				const element = open < 0 ? written : written.slice(0, open);
				const count = open < 0 ? 1 : written.slice(open + 1, written.length - 1).parseInt();
				let size = 0;
				let align = 1;
				if (element == "uint8" || element == "int8" || element == "boolean") { size = 1; }
				if (element == "uint16" || element == "int16") { size = 2; align = 2; }
				if (element == "uint32" || element == "int32") { size = 4; align = 4; }
				if (element == "uint64" || element == "int64") { size = 8; align = 8; }
				if (element == "Pubkey") { size = 32; }
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
							typeNames[l] + "' at '" + decl.interfaceFields[f] + "'; Anchor's " +
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
							" byte(s) of C padding before field '" + decl.interfaceFields[f] +
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
