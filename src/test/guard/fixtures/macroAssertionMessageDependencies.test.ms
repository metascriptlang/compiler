const messageOnlyConstant = "constant-message-payload";

function messageOnlyHelper(): string { return "helper-message-payload"; }

enum MessageOnlyKind { First, Second }

function messageKind(value: MessageOnlyKind): MessageOnlyKind { return value; }

let messageEvaluations: int32 = 0;
function lazyMessage(): string {
	messageEvaluations = messageEvaluations + 1;
	return "passing-assertion-message";
}

test "assert message constant dependency" {
	assert false, messageOnlyConstant;
}

test "assert message function dependency" {
	assert false, messageOnlyHelper();
}

test "assert message enum dependency" {
	const kind = messageKind(MessageOnlyKind.Second);
	assert false, "enum-message-" + kind.toString();
}

test "successful assertions do not evaluate messages" {
	const before = messageEvaluations;
	assert true, lazyMessage();
	assert messageEvaluations == before;
}
