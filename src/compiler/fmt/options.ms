// Format Options — configuration for msc fmt
// Matches the "format" section in msc.json

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
	printWidth: number;      // Default: 80
	tabWidth: number;        // Default: 2
	useTabs: boolean;        // Default: false
	semi: boolean;           // Default: true
	singleQuote: boolean;    // Default: false
	trailingComma: TrailingComma; // Default: All
	bracketSpacing: boolean; // Default: true
	arrowParens: ArrowParens; // Default: Always
}

export function defaultFormatOptions(): FormatOptions {
	return {
		printWidth: 80,
		tabWidth: 2,
		useTabs: false,
		semi: true,
		singleQuote: false,
		trailingComma: TrailingComma.All,
		bracketSpacing: true,
		arrowParens: ArrowParens.Always,
	};
}
