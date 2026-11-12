// Handoff tier: the checker's macro expansion and the meta frame stack it keeps.
// Siblings: macroExpansionBoundary.ms, hostCallbackBeforeBody.ms.
import { compileToCWithStd } from "../helpers";
import { activeMetaCtx } from "../../compiler/meta/callbacks";
import { ensureHostTableLoaded } from "../../compiler/meta/hostTable";
import { registerHostFn, HostCapability, _resetHostRegistryForTests, RaiserHostFn } from "../../raiser/hostRegistry";
import { RaiserValue } from "../../raiser/value";

const THROWN = "internal: test host call refused";

function compileMacroWithThrowingHost(): string {
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	const refuse: RaiserHostFn = (args: RaiserValue[]): RaiserValue => { throw new Error(THROWN); };
	registerHostFn("std/core/string/caseText.trim", refuse, HostCapability.Pure);
	let thrown = "";
	try {
		compileToCWithStd(`
import { Node, NodeKind } from "std/meta";

export macro trimmed(node: Node): Node {
	const v = "  a  ".trim();
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: v };
}

console.log(trimmed(0));
`);
	} catch (e) {
		thrown = (e as Error).message;
	}
	_resetHostRegistryForTests();
	ensureHostTableLoaded();
	return thrown;
}

test "a macro whose host call throws leaves no active meta frame" {
	const thrown = compileMacroWithThrowingHost();
	assert thrown == THROWN, `the host throw did not reach the caller: '${thrown}'`;
	assert activeMetaCtx() == null, "the expansion's meta frame survived the throw";
}
