import { checkOnly } from "../helpers";

const SHAPES = `
interface Circle { radius: int32 }
interface Label { text: string }
type Box = { side: int32 };
interface Pin { text: string; size?: int32 }
`;

function errorsOf(body: string): string {
	return checkOnly(SHAPES + body).errors.join("\n");
}

test "in keeps the members that declare the property in the true branch and the rest in the false branch" {
	assert errorsOf("function f(u: Circle | Label): int32 { if (\"radius\" in u) { return u.radius; } return u.text.length; }\n") == "";
	assert errorsOf("function f(u: Circle | Label): string { if (!(\"radius\" in u)) { return u.text; } return \"c\"; }\n") == "";
	assert errorsOf("function f(u: Circle | Box | Label): int32 { if (\"radius\" in u) { return u.radius; } if (\"side\" in u) { return u.side; } return u.text.length; }\n") == "";
}

test "in leaves a member with the property optional in both branches" {
	assert errorsOf("function f(u: Label | Pin): string { if (\"size\" in u) { return u.text; } return u.text; }\n") == "";
	const trueBranch = errorsOf("function f(u: Circle | Pin): int32 { if (\"size\" in u) { return u.radius; } return 0; }\n");
	assert trueBranch.contains("radius"), trueBranch;
}

test "in narrows away the wrong member and leaves a name no member declares alone" {
	const wrong = errorsOf("function f(u: Circle | Label): int32 { if (\"radius\" in u) { return u.text.length; } return 0; }\n");
	assert wrong.contains("text"), wrong;
	const unknown = errorsOf("function f(u: Circle | Label): int32 { if (\"nope\" in u) { return 1; } return 0; }\n");
	assert unknown == "", unknown;
}
