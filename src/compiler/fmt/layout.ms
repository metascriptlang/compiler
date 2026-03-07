// Layout Engine — transforms Doc Tree → String
// Implements the "Measure and Break" greedy algorithm for pretty printing.

import { FormatOptions } from "./options";
import { Doc, DocKind, DocData } from "./doc";

interface LayoutState {
	options: FormatOptions;
	indent: number;
	column: number;
	result: string;
	brokenGroups: boolean[]; // Parallel to Doc structure for group-break tracking
	lineSuffixes: Doc[];     // Buffered LineSuffix content, flushed before newlines
}

// Result of a "measure" pass
interface MeasureResult {
	width: number;
	fits: boolean;
}

export function formatDoc(doc: Doc, options: FormatOptions): string {
	const state: LayoutState = {
		options,
		indent: 0,
		column: 0,
		result: "",
		brokenGroups: [],
		lineSuffixes: [],
	};

	renderDoc(doc, false, state);
	flushLineSuffixes(state);
	// Ensure trailing newline
	if (state.result.length > 0 && state.result[state.result.length - 1] !== "\n") {
		state.result = state.result + "\n";
	}
	return state.result;
}

// Recursive renderer for the Doc IR
function renderDoc(doc: Doc, isBroken: boolean, state: LayoutState): void {
	match (doc.kind) {
		DocKind.Nil => {},
		DocKind.Text => {
			const d = doc.data as { text: string };
			state.result = state.result + d.text;
			state.column = state.column + d.text.length;
		},
		DocKind.Group => {
			const d = doc.data as { children: Doc[] };
			// Measure if the group fits on one line
			const fits = fitsOnOneLine(doc, state.options.printWidth - state.column);
			for (const child of d.children) {
				renderDoc(child, !fits, state);
			}
		},
		DocKind.Indent => {
			const d = doc.data as { children: Doc[] };
			state.indent = state.indent + state.options.tabWidth;
			for (const child of d.children) {
				renderDoc(child, isBroken, state);
			}
			state.indent = state.indent - state.options.tabWidth;
		},
		DocKind.Line => {
			const d = doc.data as { isSoft: boolean };
			if (isBroken) {
				flushLineSuffixes(state);
				state.result = state.result + "\n";
				for (let j = 0; j < state.indent; j += 1) {
					state.result = state.result + " ";
				}
				state.column = state.indent;
			} else if (!d.isSoft) {
				state.result = state.result + " ";
				state.column = state.column + 1;
			}
		},
		DocKind.HardLine => {
			flushLineSuffixes(state);
			state.result = state.result + "\n";
			for (let k = 0; k < state.indent; k += 1) {
				state.result = state.result + " ";
			}
			state.column = state.indent;
		},
		DocKind.IfBreak => {
			const d = doc.data as { flat: Doc, broken: Doc };
			if (isBroken) {
				renderDoc(d.broken, true, state);
			} else {
				renderDoc(d.flat, false, state);
			}
		},
		DocKind.LineSuffix => {
			state.lineSuffixes.push(doc);
		},
		_ => {},
	};
}

function flushLineSuffixes(state: LayoutState): void {
	if (state.lineSuffixes.length === 0) return;
	for (const suffix of state.lineSuffixes) {
		const d = suffix.data as { children: Doc[] };
		for (const child of d.children) {
			renderDoc(child, false, state);
		}
	}
	state.lineSuffixes = [];
}

// Simple greedy measurement: does the flat version of this doc fit in 'rem' space?
function fitsOnOneLine(doc: Doc, rem: number): boolean {
	if (rem < 0) return false;

	return match (doc.kind) {
		DocKind.Nil => true,
		DocKind.Text => {
			const d = doc.data as { text: string };
			d.text.length <= rem
		},
		DocKind.Group | DocKind.Indent => {
			const d = doc.data as { children: Doc[] };
			let totalWidth = 0;
			let fits = true;
			let i = 0;
			while (i < d.children.length && fits) {
				totalWidth = totalWidth + getFlatWidth(d.children[i]);
				if (totalWidth > rem) { fits = false; }
				i = i + 1;
			}
			fits
		},
		DocKind.Line => {
			const d = doc.data as { isSoft: boolean };
			d.isSoft ? true : 1 <= rem
		},
		DocKind.HardLine => false, // HardLine ALWAYS forces a break
		DocKind.IfBreak => {
			const d = doc.data as { flat: Doc };
			getFlatWidth(d.flat) <= rem
		},
		_ => true,
	};
}

// Calculate the width of the doc if it were printed entirely flat
function getFlatWidth(doc: Doc): number {
	return match (doc.kind) {
		DocKind.Nil => 0,
		DocKind.Text => (doc.data as { text: string }).text.length,
		DocKind.Group | DocKind.Indent => {
			const d = doc.data as { children: Doc[] };
			let w = 0;
			for (const child of d.children) {
				w = w + getFlatWidth(child);
			}
			w
		},
		DocKind.Line => (doc.data as { isSoft: boolean }).isSoft ? 0 : 1,
		DocKind.HardLine => 1000, // Effectively infinite width to force break
		DocKind.IfBreak => getFlatWidth((doc.data as { flat: Doc }).flat),
		_ => 0,
	};
}
