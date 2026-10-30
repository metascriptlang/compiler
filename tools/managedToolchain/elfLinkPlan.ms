import { basename } from "std/fs";

export enum ElfLinkItemKind { Argument, InputPath, UserObject }

export struct ElfLinkItem {
	kind: ElfLinkItemKind;
	value: string;
}

export struct ElfLinkPlan {
	linker: string;
	items: ElfLinkItem[];
}

const VALUED_FLAGS: string[] = [
	"-z", "--entry", "-m", "--dynamic-linker", "-mllvm",
];

function place(index: int64): string {
	return "tokens[" + String(index) + "]: ";
}

// InputPath values are unvalidated tokens. The consumer must resolve them
// against the command's cwd and require regular files in its private cache.
export function parseElfLinkArguments(
	tokens: Readonly<Span<string>>, output: string, objectName: string,
): Result<ElfLinkPlan, string> {
	if (output == "" || output.indexOf("\0") >= 0) {
		return Result.err("link output is empty or contains NUL");
	}
	if (objectName == "" || objectName.indexOf("\0") >= 0) {
		return Result.err("fixture object name is empty or contains NUL");
	}
	if (tokens.length == 0) { return Result.err("link command has no linker"); }
	for (let index: int64 = 0; index < tokens.length; index += 1) {
		if (tokens[index] == "" || tokens[index].indexOf("\0") >= 0) {
			return Result.err(place(index) + "argument is empty or contains NUL");
		}
	}
	const items: ElfLinkItem[] = [];
	let users: int64 = 0;
	let index: int64 = 1;
	while (index < tokens.length) {
		const token = tokens[index];
		if (token == "-o" || VALUED_FLAGS.indexOf(token) >= 0) {
			if (index + 1 >= tokens.length) {
				return Result.err(place(index) + token + " has no value");
			}
			const value = tokens[index + 1];
			if (token == "-o") {
				if (value != output) {
					return Result.err(place(index) + "link line writes " + value +
						", not " + output);
				}
			} else {
				items.push({ kind: ElfLinkItemKind.Argument, value: token });
				items.push({ kind: ElfLinkItemKind.Argument, value });
			}
			index += 2;
		} else {
			if (token.startsWith("-")) {
				items.push({ kind: ElfLinkItemKind.Argument, value: token });
			} else if (basename(token) == objectName) {
				items.push({ kind: ElfLinkItemKind.UserObject, value: "" });
				users += 1;
			} else {
				items.push({ kind: ElfLinkItemKind.InputPath, value: token });
			}
			index += 1;
		}
	}
	if (users != 1) {
		return Result.err("link line names the fixture object " + objectName +
			" " + String(users) + " times");
	}
	return Result.ok({ linker: basename(tokens[0]), items });
}
