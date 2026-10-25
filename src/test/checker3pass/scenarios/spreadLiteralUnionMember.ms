import { checkOnly, findFirstByKind } from "../helpers";
import { Node, NodeKind } from "../../../ast/node";
import { peelToStruct } from "../../../checker/types";

function chosenMember(source: string): string {
	const result = checkOnly(source);
	if (result.errors.length > 0) return "errors: " + result.errors.join("\n");
	const literal: Node = findFirstByKind(result.program, NodeKind.ObjectLiteral);
	if (literal == null || literal.nodeType == null) return "untyped literal";
	if (literal.variantSlot <= 0) return "no member chosen";
	const member = peelToStruct(literal.nodeType.typeChildren[literal.variantSlot - 1]);
	return member == null ? "member is not a struct" : member.typeName;
}

const SRC_SAME_NAMES = `
struct NumBox { v: int32; }
struct StrBox { v: string; }
function pick(b: NumBox | StrBox): int32 { return 1; }
function f(s: StrBox): int32 { return pick({ ...s }); }
`;

const SRC_OVERRIDE = `
struct NumBox { v: int32; }
struct StrBox { v: string; }
function pick(b: NumBox | StrBox): int32 { return 1; }
function f(n: NumBox): int32 { return pick({ ...n, v: 4 }); }
`;

const SRC_BESIDE_FUNCTION = `
struct Paint { alpha: float32; width: float32; }
function take(value: Paint | ((previous: Paint) => Paint)): void {}
function f(initial: Paint): void { take({ ...initial, alpha: 0.75 }); }
`;

test "a spread literal against same-named members takes the member its operand's field types fit" {
	const chosen = chosenMember(SRC_SAME_NAMES);
	assert chosen == "StrBox", "{ ...s } with s: StrBox must build StrBox, not the first member holding 'v': " + chosen;
}

test "a spread literal with an overriding field takes the member of the spread operand" {
	const chosen = chosenMember(SRC_OVERRIDE);
	assert chosen == "NumBox", "{ ...n, v: 4 } with n: NumBox must build NumBox: " + chosen;
}

test "a spread literal beside a function member builds the struct member" {
	const chosen = chosenMember(SRC_BESIDE_FUNCTION);
	assert chosen == "Paint", "{ ...initial, alpha } into Paint | fn must build Paint: " + chosen;
}
