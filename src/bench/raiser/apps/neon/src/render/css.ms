// CSS text for a Style at run time — what the string renderer writes into a
// `style="…"` attribute (docs/STYLE.md §5).
//
// Third spelling of the same vocabulary, beside the rule text the macro bakes
// at expansion (macros/ui/style.ms cssDecl) and the CSSOM writes in
// platform/browser/dom.jms. Kept apart for the same reason those two are: each
// consumes a different form — a Node at expansion, a CSSOM object, a runtime
// Style. tests/render/ssrStyle.test.ms pins this one against the macro's rule
// text so the pair cannot drift apart silently.
//
// One emitter per unit rule rather than one emitter plus a name table: the
// call site already knows whether a field is a length, a bare ratio or a word,
// same split as len/num/word in the DOM host.

import { Style } from "./style";
import { styleToCssBody } from "../macros/style/fields";

function kebabCase(name: string): string {
	const lower = "abcdefghijklmnopqrstuvwxyz";
	let out = "";
	for (let i = 0; i < name.length; i += 1) {
		const c = name.charCodeAt(i);
		if (c >= 65 && c <= 90) {
			out = out + "-" + lower.charAt(c - 65);
		} else {
			out = out + name.charAt(i);
		}
	}
	return out;
}

// A bare number is points, which on the web is px; a string is already CSS.
function cssLen(name: string, v: number | string | null): string {
	if (v === null) { return ""; }
	if (typeof v === "string") { return v === "" ? "" : kebabCase(name) + ":" + (v as string) + ";"; }
	return kebabCase(name) + ":" + `${v as number}` + "px;";
}

function cssPx(name: string, v: number | null): string {
	if (v === null) { return ""; }
	return kebabCase(name) + ":" + `${v as number}` + "px;";
}

// flex, the flex ratios, aspectRatio, opacity — unitless in CSS too.
function cssRatio(name: string, v: number | null): string {
	if (v === null) { return ""; }
	return kebabCase(name) + ":" + `${v as number}` + ";";
}

function cssWord(name: string, v: string | null): string {
	if (v === null || v === "") { return ""; }
	return kebabCase(name) + ":" + (v as string) + ";";
}

// Field by field in declaration order, because unset is `null` rather than
// absence and the flat IR has no key iteration.
styleToCssBody(0);
