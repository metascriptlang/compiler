// @stdout: arc-contextual 8 first 9 second
struct ArcData { value: int32; label: string; }

function returnedLiteral(): Arc<ArcData> { return { value: 8, label: "first" }; }
function boundLiteral(): Arc<ArcData> {
	const value: Arc<ArcData> = { value: 9, label: "second" };
	return value;
}
function observeArcLiterals(): void {
	const a = returnedLiteral();
	const b = boundLiteral();
	console.log("arc-contextual", a.value, a.label, b.value, b.label);
}
observeArcLiterals();
