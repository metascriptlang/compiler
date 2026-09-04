// Format Options — configuration for msc fmt
// Reads from build.ms `fmt` section via FmtSection.

import { FmtSection } from "../buildConfig";

export enum TrailingComma {
	All,
	Es5,
	None,
}

export enum ArrowParens {
	Always,
	Avoid,
}

export interface FormatOptions {
	printWidth: int32;      // Default: 80
	tabWidth: int32;        // Default: 2
	useTabs: boolean;        // Default: false
	semi: boolean;           // Default: true
	singleQuote: boolean;    // Default: false
	trailingComma: TrailingComma; // Default: All
	bracketSpacing: boolean; // Default: true
	arrowParens: ArrowParens; // Default: Always
	source: string;          // Original source text (for raw token extraction)
}

export function defaultFormatOptions(): FormatOptions {
	return {
		printWidth: 80,
		tabWidth: 2,
		source: "",
		useTabs: false,
		semi: true,
		singleQuote: false,
		trailingComma: TrailingComma.All,
		bracketSpacing: true,
		arrowParens: ArrowParens.Always,
	};
}

// Context for trailing comma decisions.
export enum CommaContext {
	Params,      // function/method/arrow params and call/new args
	Collection,  // objects, arrays, imports
}

// Should a trailing comma appear in this context?
export function wantsTrailingComma(opts: FormatOptions, context: CommaContext): boolean {
	if (opts.trailingComma === TrailingComma.All) return true;
	if (opts.trailingComma === TrailingComma.Es5 && context === CommaContext.Collection) return true;
	return false;
}

// Apply build.ms fmt overrides to default options.
// FmtSection uses -1 as "unset" sentinel for numbers and booleans.
export function applyFmtSection(opts: FormatOptions, fmt: FmtSection): FormatOptions {
	if (fmt.printWidth >= 0) { opts.printWidth = fmt.printWidth; }
	if (fmt.tabWidth >= 0) { opts.tabWidth = fmt.tabWidth; }
	if (fmt.useTabs >= 0) { opts.useTabs = fmt.useTabs === 1; }
	if (fmt.singleQuote >= 0) { opts.singleQuote = fmt.singleQuote === 1; }
	return opts;
}
