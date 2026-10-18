import { Node, NodeKind, createNodeAt, stringValue } from "std/meta";

export macro securityTxt(fields: Node): Node {
	const KEYS: string[] = [
		"name", "projectUrl", "contacts", "policy",
		"preferredLanguages", "encryption", "sourceCode", "sourceRevision", "sourceRelease",
		"auditors", "acknowledgements", "expiry",
	];
	const WIRE: string[] = [
		"name", "project_url", "contacts", "policy",
		"preferred_languages", "encryption", "source_code", "source_revision", "source_release",
		"auditors", "acknowledgements", "expiry",
	];
	const REQUIRED = 4;
	const octal = "01234567";

	function refuse(parts: string[], at: Node): void {
		const message = parts.join("");
		error(message, at);
	}

	function cBytes(into: string[], bytes: Readonly<Span<uint8>>): void {
		for (let i = 0; i < bytes.length; i += 1) {
			const b = bytes[i] as int32;
			into.push("\\");
			into.push(octal.slice((b >> 6) & 7, ((b >> 6) & 7) + 1));
			into.push(octal.slice((b >> 3) & 7, ((b >> 3) & 7) + 1));
			into.push(octal.slice(b & 7, (b & 7) + 1));
		}
	}

	if (fields.kind !== NodeKind.ObjectLiteral) {
		refuse(["securityTxt(fields): fields must be an object literal, securityTxt({ name: \"…\", projectUrl: \"…\", contacts: \"…\", policy: \"…\" })"], fields);
	}
	const written: string[] = [];
	const block: string[] = [];
	cBytes(block, "=======BEGIN SECURITY.TXT V1=======".asBytes());
	block.push("\\000");
	for (let i = 0; i < fields.keys.length; i += 1) {
		const key = fields.keys[i];
		const at = KEYS.indexOf(key);
		if (at < 0) {
			refuse(["securityTxt: unknown field '", key, "'; the fields are ", KEYS.join(", ")], fields.properties[i]);
		}
		if (written.includes(key)) {
			refuse(["securityTxt: field '", key, "' is written twice"], fields.properties[i]);
		}
		written.push(key);
		const value = fields.properties[i];
		if (value.kind !== NodeKind.StringLiteral) {
			refuse(["securityTxt: field '", key, "' must be a string literal known at compile time"], value);
		}
		const text = stringValue(value);
		const bytes = text.asBytes();
		for (let b = 0; b < bytes.length; b += 1) {
			if (bytes[b] == 0) {
				refuse(["securityTxt: field '", key, "' contains a NUL byte, which ends the value in the block"], value);
			}
		}
		if (text.includes("SECURITY.TXT V1=======")) {
			refuse(["securityTxt: field '", key, "' contains a security.txt marker, which a reader would take for the block's edge"], value);
		}
		cBytes(block, WIRE[at].asBytes());
		block.push("\\000");
		cBytes(block, bytes);
		block.push("\\000");
	}
	for (let i = 0; i < REQUIRED; i += 1) {
		if (!written.includes(KEYS[i])) {
			refuse(["securityTxt: required field '", KEYS[i], "' is missing"], fields);
		}
	}
	when (js) {
		return quote {};
	}
	cBytes(block, "=======END SECURITY.TXT V1=======".asBytes());
	block.push("\\000");
	const code: Node = createNodeAt(NodeKind.StringLiteral, {
		value: ["__attribute__((used, retain, visibility(\"hidden\"))) const char msSecurityTxt[] = \"", block.join(""), "\";"].join(""),
	}, fields.location);
	const emitted: Node = createNodeAt(NodeKind.MacroInvocation, { macroName: "emit", macroArgs: [code], macroHasParens: true }, fields.location);
	return emitted;
}
