// Layout Engine — transforms Doc Tree → String
// Iterative stack-based printer (Prettier/Biome pattern).
// Uses a command stack instead of recursion to avoid stack overflow
// and enable rest-of-line measurement in fits().

import { FormatOptions } from "./options";
import { Doc, DocKind, DocData } from "./doc";

// Mode: flat (try to fit on one line) or break (multi-line)
const MODE_FLAT = 0;
const MODE_BREAK = 1;

// Command: a triple pushed onto the print stack.
interface Cmd {
	indent: int32;
	mode: int32;
	doc: Doc;
}

// Pre-pass: propagate break markers upward through the doc tree.
// If a group contains a BreakParent or HardLine, it must break — and its parent group too.
// Returns true if the subtree forces a break.
function propagateBreaks(doc: Doc): boolean {
	if (doc == null) return false;
	if (doc.kind == DocKind.BreakParent || doc.kind == DocKind.HardLine) return true;
	if (doc.kind == DocKind.Group || doc.kind == DocKind.Indent || doc.kind == DocKind.LineSuffix) {
		const d = doc.data as { children: Doc[] };
		let hasBreak = false;
		for (const child of d.children) {
			if (propagateBreaks(child)) hasBreak = true;
		}
		if (hasBreak && doc.kind == DocKind.Group) {
			doc.shouldBreak = true;
		}
		return hasBreak;
	}
	if (doc.kind == DocKind.IfBreak) {
		const d = doc.data as { broken: Doc, flat: Doc };
		propagateBreaks(d.flat);
		propagateBreaks(d.broken);
	}
	return false;
}

// Flush line suffix content directly to result string.
function flushSuffixes(lineSuffixes: Doc[]): string {
	let out = "";
	for (const ls of lineSuffixes) {
		const lsChildren = (ls.data as { children: Doc[] }).children;
		for (const lsc of lsChildren) {
			if (lsc.kind == DocKind.Text) {
				out = out + (lsc.data as { text: string }).text;
			}
		}
	}
	lineSuffixes.length = 0;
	return out;
}

// Emit indentation string — tabs when useTabs, spaces otherwise.
function makeIndentStr(indent: int32, options: FormatOptions): string {
	if (options.useTabs) {
		const tabCount = indent / options.tabWidth;
		let s = "";
		for (let i = 0; i < tabCount; i += 1) {
			s = s + "\t";
		}
		return s;
	}
	let s = "";
	for (let i = 0; i < indent; i += 1) {
		s = s + " ";
	}
	return s;
}

// Measure if content fits in remaining width.
// Prettier pattern: simulates printing the doc AND the rest of the command stack
// to determine if everything fits on the current line.
function fits(next: Cmd, restStack: Cmd[], restIdx: number, rem: number): boolean {
	// Local simulation stack — start with the candidate command
	const stack: Cmd[] = [next];
	let remaining = rem;

	while (stack.length > 0) {
		if (remaining < 0) return false;

		const cmd = stack[stack.length - 1];
		stack.length = stack.length - 1;
		const doc = cmd.doc;

		if (doc == null) continue;

		if (doc.kind == DocKind.Nil || doc.kind == DocKind.BreakParent) {
			continue;
		}
		if (doc.kind == DocKind.Text) {
			remaining = remaining - (doc.data as { text: string }).text.length;
			continue;
		}
		if (doc.kind == DocKind.Group) {
			// A group with shouldBreak can never fit flat — fail immediately
			if (doc.shouldBreak) return false;
			const d = doc.data as { children: Doc[] };
			let j = d.children.length - 1;
			while (j >= 0) {
				stack.push({ indent: cmd.indent, mode: cmd.mode, doc: d.children[j] });
				j = j - 1;
			}
			continue;
		}
		if (doc.kind == DocKind.Indent) {
			const d = doc.data as { children: Doc[] };
			let j = d.children.length - 1;
			while (j >= 0) {
				stack.push({ indent: cmd.indent + 1, mode: cmd.mode, doc: d.children[j] });
				j = j - 1;
			}
			continue;
		}
		if (doc.kind == DocKind.Line) {
			const d = doc.data as { isSoft: boolean };
			if (cmd.mode == MODE_BREAK) {
				return true; // Line break in break mode — rest doesn't matter, fits
			}
			if (!d.isSoft) {
				remaining = remaining - 1; // Space in flat mode
			}
			continue;
		}
		if (doc.kind == DocKind.HardLine) {
			return true; // Hard line always fits (forces break)
		}
		if (doc.kind == DocKind.IfBreak) {
			const d = doc.data as { broken: Doc, flat: Doc };
			if (cmd.mode == MODE_BREAK) {
				stack.push({ indent: cmd.indent, mode: cmd.mode, doc: d.broken });
			} else {
				stack.push({ indent: cmd.indent, mode: cmd.mode, doc: d.flat });
			}
			continue;
		}
		if (doc.kind == DocKind.LineSuffix) {
			continue; // Line suffixes don't contribute to width measurement
		}
	}

	// Local stack empty — check rest of the main stack (rest-of-line measurement).
	// Only measure until the next line break — content after a newline doesn't affect fit.
	while (restIdx >= 0) {
		if (remaining < 0) return false;
		const cmd = restStack[restIdx];
		restIdx = restIdx - 1;
		const doc = cmd.doc;

		if (doc == null || doc.kind == DocKind.Nil || doc.kind == DocKind.BreakParent) continue;
		if (doc.kind == DocKind.Text) {
			remaining = remaining - (doc.data as { text: string }).text.length;
			continue;
		}
		if (doc.kind == DocKind.HardLine) return true;
		if (doc.kind == DocKind.Line) {
			if (cmd.mode == MODE_BREAK) return true;
			if (!(doc.data as { isSoft: boolean }).isSoft) remaining = remaining - 1;
			continue;
		}
		// Stop rest-of-line scan at compound docs in break mode —
		// they will produce newlines, so content after them is irrelevant.
		if (cmd.mode == MODE_BREAK) return true;
		if (doc.kind == DocKind.IfBreak) {
			remaining = remaining - getFlatWidth((doc.data as { broken: Doc, flat: Doc }).flat);
			continue;
		}
	}

	return remaining >= 0;
}

// Calculate flat width of a doc (used by fits rest-of-line fallback)
function getFlatWidth(doc: Doc): int32 {
	if (doc == null) return 0;
	return match (doc.kind) {
		DocKind.Nil | DocKind.BreakParent | DocKind.LineSuffix => 0,
		DocKind.Text => (doc.data as { text: string }).text.length,
		DocKind.Group | DocKind.Indent => {
			const d = doc.data as { children: Doc[] };
			let w = 0;
			for (const child of d.children) { w = w + getFlatWidth(child); }
			return w;
		},
		DocKind.Line => (doc.data as { isSoft: boolean }).isSoft ? 0 : 1,
		DocKind.HardLine => 1000,
		DocKind.IfBreak => getFlatWidth((doc.data as { broken: Doc, flat: Doc }).flat),
		_ => 0,
	};
}

export function formatDoc(doc: Doc, options: FormatOptions): string {
	// Propagate break markers before rendering (Prettier/Biome parity)
	propagateBreaks(doc);

	let result = "";
	let column = 0;
	const lineSuffixes: Doc[] = [];
	// Track group break decisions by ID for cross-group IfBreak
	const groupModes: int32[] = []; // groupId → MODE_FLAT or MODE_BREAK

	// Command stack — push in reverse order so children pop in correct order
	const stack: Cmd[] = [{ indent: 0, mode: MODE_BREAK, doc }];

	while (stack.length > 0) {
		const cmd = stack[stack.length - 1];
		stack.length = stack.length - 1;
		const d = cmd.doc;

		if (d == null || d.kind == DocKind.Nil || d.kind == DocKind.BreakParent) continue;

		if (d.kind == DocKind.Text) {
			const text = (d.data as { text: string }).text;
			result = result + text;
			column = column + text.length;
			continue;
		}

		if (d.kind == DocKind.Group) {
			const children = (d.data as { children: Doc[] }).children;
			let childMode: int32;
			if (d.shouldBreak) {
				childMode = MODE_BREAK;
			} else {
				const flatCmd: Cmd = { indent: cmd.indent, mode: MODE_FLAT, doc: d };
				const groupFits = fits(flatCmd, stack, stack.length - 1, options.printWidth - column);
				childMode = groupFits ? MODE_FLAT : MODE_BREAK;
			}
			// Record break decision for cross-group IfBreak references
			if (d.groupId > 0) {
				while (groupModes.length <= d.groupId) { groupModes.push(0); }
				groupModes[d.groupId] = childMode;
			}
			let j = children.length - 1;
			while (j >= 0) {
				stack.push({ indent: cmd.indent, mode: childMode, doc: children[j] });
				j = j - 1;
			}
			continue;
		}

		if (d.kind == DocKind.Indent) {
			const children = (d.data as { children: Doc[] }).children;
			let j = children.length - 1;
			while (j >= 0) {
				stack.push({ indent: cmd.indent + 1, mode: cmd.mode, doc: children[j] });
				j = j - 1;
			}
			continue;
		}

		if (d.kind == DocKind.Line) {
			if (cmd.mode == MODE_BREAK) {
				if (lineSuffixes.length > 0) { result = result + flushSuffixes(lineSuffixes); }
				const indentStr = makeIndentStr(cmd.indent * options.tabWidth, options);
				result = result + "\n" + indentStr;
				column = cmd.indent * options.tabWidth;
			} else {
				// Flat mode: soft line = nothing, regular line = space
				if (!(d.data as { isSoft: boolean }).isSoft) {
					result = result + " ";
					column = column + 1;
				}
			}
			continue;
		}

		if (d.kind == DocKind.HardLine) {
			if (lineSuffixes.length > 0) { result = result + flushSuffixes(lineSuffixes); }
			const indentStr = makeIndentStr(cmd.indent * options.tabWidth, options);
			result = result + "\n" + indentStr;
			column = cmd.indent * options.tabWidth;
			continue;
		}

		if (d.kind == DocKind.IfBreak) {
			const ifData = d.data as { broken: Doc, flat: Doc };
			// Check specific group's mode if groupId is set, otherwise use current mode
			let isBroken = cmd.mode == MODE_BREAK;
			if (d.groupId > 0 && d.groupId < groupModes.length) {
				isBroken = groupModes[d.groupId] == MODE_BREAK;
			}
			if (isBroken) {
				stack.push({ indent: cmd.indent, mode: cmd.mode, doc: ifData.broken });
			} else {
				stack.push({ indent: cmd.indent, mode: cmd.mode, doc: ifData.flat });
			}
			continue;
		}

		if (d.kind == DocKind.LineSuffix) {
			lineSuffixes.push(d);
			continue;
		}

		if (d.kind == DocKind.Fill) {
			// Fill: pack items with separators, wrapping per-pair.
			// children alternate: [item, sep, item, sep, item]
			// Must push in reverse so they process left-to-right.
			// But each separator's mode depends on whether the NEXT item fits,
			// which depends on the current column — a chicken-and-egg problem.
			// Solution: push remaining items as a nested Fill, process first pair now.
			const parts = (d.data as { children: Doc[] }).children;
			if (parts.length == 0) { continue; }

			// Push remaining pairs as a new Fill (processed after current pair)
			if (parts.length > 2) {
				const rest: Doc[] = [];
				let ri = 2;
				while (ri < parts.length) {
					rest.push(parts[ri]);
					ri = ri + 1;
				}
				const restFill = new Doc();
				restFill.kind = DocKind.Fill;
				restFill.data = { children: rest } as DocData;
				restFill.shouldBreak = false;
				restFill.groupId = 0;
				stack.push({ indent: cmd.indent, mode: cmd.mode, doc: restFill });
			}

			// Determine if item[0] + sep[1] + item[2] fits on current line
			const itemWidth = getFlatWidth(parts[0]);
			const sepWidth = (parts.length > 1) ? getFlatWidth(parts[1]) : 0;
			const nextWidth = (parts.length > 2) ? getFlatWidth(parts[2]) : 0;
			const rem = options.printWidth - column;

			if (parts.length > 1) {
				if (itemWidth + sepWidth + nextWidth <= rem) {
					// Both fit — emit separator flat
					stack.push({ indent: cmd.indent, mode: MODE_FLAT, doc: parts[1] });
				} else {
					// Doesn't fit — break separator
					stack.push({ indent: cmd.indent, mode: MODE_BREAK, doc: parts[1] });
				}
			}
			// Always emit first item flat
			stack.push({ indent: cmd.indent, mode: MODE_FLAT, doc: parts[0] });
			continue;
		}
	}

	// Flush remaining line suffixes
	if (lineSuffixes.length > 0) { result = result + flushSuffixes(lineSuffixes); }

	// Ensure trailing newline
	if (result.length > 0 && result[result.length - 1] != "\n") {
		result = result + "\n";
	}
	return result;
}
