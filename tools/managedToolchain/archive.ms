import { utf8String, wellFormedString } from "std/core/string/bytes";
import { wellFormedPrefix } from "std/core/string/utf8Repair";

const MAGIC = "!<arch>\n";
const HEADER_SIZE: int64 = 60;
const NAME_SIZE: int64 = 16;
const SIZE_START: int64 = 48;
const SIZE_END: int64 = 58;

export struct ArchiveMember {
	name: string;
	data: Buffer;
}

function asciiName(data: Readonly<Span<uint8>>): Result<string, string> {
	for (const byte of data) {
		if (byte > 127) { return Result.err("ar member name is not ASCII"); }
	}
	let name = utf8String(data, false);
	while (name.endsWith(" ")) { name = name.slice(0, name.length - 1); }
	return Result.ok(name);
}

function decimal(text: string): Result<int64, string> {
	if (text == "" || text.length > 16) {
		return Result.err("ar decimal field has invalid length");
	}
	let value: int64 = 0;
	for (let i: int32 = 0; i < text.length; i += 1) {
		const code = text.charCodeAt(i);
		if (code < "0".code || code > "9".code) {
			return Result.err("ar decimal field contains a non-digit");
		}
		value = value * 10 + ((code - "0".code) as int64);
	}
	return Result.ok(value);
}

function sizeText(data: Readonly<Span<uint8>>): string {
	let start: int64 = 0;
	let end = data.length as int64;
	while (start < end && data[start] == " ".code) { start += 1; }
	while (end > start && data[end - 1] == " ".code) { end -= 1; }
	return utf8String(data[start..end], false);
}

function memberName(data: Readonly<Span<uint8>>): Result<string, string> {
	if (wellFormedPrefix(data, 0, false) != data.length) {
		return Result.err("ar member name is not UTF-8");
	}
	const name = wellFormedString(data);
	if (name == "" || name.startsWith(" ") || name.indexOf("\0") >= 0) {
		return Result.err("invalid ar member name");
	}
	return Result.ok(name);
}

function isSymbolTable(name: string): boolean {
	return name == "__.SYMDEF" || name == "__.SYMDEF SORTED" ||
		name == "__.SYMDEF_64" || name == "__.SYMDEF_64 SORTED";
}

export function parseArchive(
	data: Readonly<Span<uint8>>,
): Result<ArchiveMember[], string> {
	const magic = MAGIC.asBytes();
	if (data.length < magic.length) { return Result.err("not an ar archive"); }
	for (let i: int32 = 0; i < magic.length; i += 1) {
		if (data[i] != magic[i]) { return Result.err("not an ar archive"); }
	}
	const members: ArchiveMember[] = [];
	let longNames = data[0..0];
	let memberIndex: int64 = 0;
	let firstLinker = false;
	let coff = false;
	let offset = magic.length as int64;
	while (offset < data.length) {
		if (data.length - offset < HEADER_SIZE ||
			data[offset + SIZE_END] != "`".code ||
			data[offset + SIZE_END + 1] != "\n".code) {
			return Result.err("bad ar member header at " + String(offset));
		}
		const rawName = asciiName(data[offset..offset + NAME_SIZE]);
		if (!rawName.ok) {
			return Result.err(rawName.error + " at " + String(offset));
		}
		const size = decimal(sizeText(
			data[offset + SIZE_START..offset + SIZE_END],
		));
		if (!size.ok) {
			return Result.err("bad ar member size at " + String(offset));
		}
		let bodyStart = offset + HEADER_SIZE;
		const available = data.length - bodyStart;
		const padding = size.value % 2;
		if (size.value > available || available - size.value < padding) {
			return Result.err("ar member at " + String(offset) + " is truncated");
		}
		const bodyEnd = bodyStart + size.value;
		offset = bodyEnd + padding;
		if (memberIndex == 0) {
			firstLinker = rawName.value == "/" || rawName.value == "/SYM64/";
		} else if (memberIndex == 1 && firstLinker && rawName.value == "/") {
			coff = true;
		}
		memberIndex += 1;
		if (rawName.value == "/" || rawName.value == "/SYM64/") { continue; }
		if (rawName.value == "//") {
			longNames = data[bodyStart..bodyEnd];
			continue;
		}
		let nameBytes = data[0..0];
		if (rawName.value.startsWith("#1/")) {
			const length = decimal(rawName.value.slice(3, rawName.value.length));
			if (!length.ok || length.value == 0 || length.value > size.value) {
				return Result.err("invalid BSD ar name length: " + rawName.value);
			}
			let nameEnd = bodyStart + length.value;
			while (nameEnd > bodyStart && data[nameEnd - 1] == 0) { nameEnd -= 1; }
			nameBytes = data[bodyStart..nameEnd];
			bodyStart += length.value;
		} else if (rawName.value.startsWith("/")) {
			const reference = decimal(rawName.value.slice(1, rawName.value.length));
			if (!reference.ok) {
				return Result.err("unsupported ar member name: " + rawName.value);
			}
			const start = reference.value;
			if (start >= longNames.length) {
				return Result.err("invalid ar long name reference: " + rawName.value);
			}
			let end = start;
			if (coff) {
				while (end < longNames.length && longNames[end] != 0) { end += 1; }
				if (end == longNames.length) {
					return Result.err("invalid ar long name reference: " + rawName.value);
				}
			} else {
				while (end + 1 < longNames.length &&
					!(longNames[end] == "/".code && longNames[end + 1] == "\n".code)) {
					end += 1;
				}
				if (end + 1 >= longNames.length) {
					return Result.err("invalid ar long name reference: " + rawName.value);
				}
			}
			nameBytes = longNames[start..end];
		} else {
			const length = rawName.value.length -
				(rawName.value.endsWith("/") ? 1 : 0);
			const headerStart = bodyStart - HEADER_SIZE;
			nameBytes = data[headerStart..headerStart + length];
		}
		const name = memberName(nameBytes);
		if (!name.ok) { return Result.err(name.error); }
		if (!isSymbolTable(name.value)) {
			members.push({ name: name.value, data: [...data[bodyStart..bodyEnd]] });
		}
	}
	return Result.ok(members);
}
