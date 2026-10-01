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
	const described: Node[] = accountTypes.concat(eventTypes);
	let d = 0;
	while (d < described.length) {
		const decl = getImpl(bindSym(described[d].name))!;
		const zeroCopy = d < accountTypes.length;
		json = json + (d > 0 ? "," : "") + "{\"name\":\"" + described[d].name + "\"";
		if (zeroCopy) { json = json + ",\"serialization\":\"bytemuck\",\"repr\":{\"kind\":\"c\"}"; }
		json = json + ",\"type\":{\"kind\":\"struct\",\"fields\":[";
		let f = 0;
		while (f < decl.interfaceFields.length) {
			const written = decl.interfaceFieldTypes[f];
			let idlType = "\"" + written + "\"";
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
			json = json + (f > 0 ? "," : "") + "{\"name\":\"" + snakeCase(decl.interfaceFields[f]) +
				"\",\"type\":" + idlType + "}";
			f = f + 1;
		}
		json = json + "]}}";
		d = d + 1;
	}
	json = json + "]}";
	return { kind: NodeKind.StringLiteral, line: spec.line, column: spec.column, value: json };
}
