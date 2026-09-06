// @stdout: maybe-fit ok on:12
//
// A call argument the checker fitted into a Maybe carrier must cross the
// macro wire in SOURCE form. synthMaybeWrap (checker/fit.ms) materializes
// T → Maybe<T> as a carrier literal { value, present } rather than a Hidden
// conv, so the wire's kind-based strip could not see it. Pre-fix the frozen
// carrier leaked through expansion and the re-check either wrapped it AGAIN
// (object-literal arg: C clang error `_lit.value = <struct>`, JS silently
// dropped the value) or mismatched its anonymous type (direct arg:
// "got __anon2__values__presentb, expected Maybe_p1"). The wire now unwraps
// the carrier by TYPE — only the checker can stamp IsMaybe on a literal.

import { Node } from "std/meta";

macro pass(node: Node): Node {
	return node;
}

type Sel = { state?: string, pad?: number };

function pick(sel: Sel): string {
	const s = sel.state == "on" ? "on" : "off";
	const p = sel.pad == null ? 0 : sel.pad;
	return s + ":" + p.toString();
}

function direct(v: string | null): string {
	return v == null ? "-" : v;
}

function main(): void {
	const viaObj = pass(pick({ state: "on", pad: 12 }));
	const viaDirect = pass(direct("x"));
	if (viaObj == "on:12" && viaDirect == "x") {
		console.log("maybe-fit ok " + viaObj);
	} else {
		console.log("maybe-fit BAD obj=" + viaObj + " direct=" + viaDirect);
	}
}

main();
