// @stdout: 2
// note: a zero-argument handler in a row an outer element macro hands back keeps its function value: the row is re-checked after the inner element macro adapted the handler, and the re-check reads the adapter as the value the author wrote (Neon <For> rows).
function Box(p: { row: (i: int32) => Thunk }): Thunk { return p.row(1); }

let hits = 0;
export function Inline(pressed: () => void): Thunk {
	return <Box>{(i: int32): Thunk => <btn on={pressed} />}</Box>;
}
export function Hoisted(pressed: () => void): Thunk {
	const row = (i: int32): Thunk => <btn on={pressed} />;
	return <Box>{row}</Box>;
}
export function Arity(pressed: (n: int32) => void): Thunk {
	return <Box>{(i: int32): Thunk => <btn on={(): void => pressed(i)} />}</Box>;
}
Inline((): void => { hits += 1; })(0, 0, 0);
Hoisted((): void => { hits += 1; })(0, 0, 0);
console.log(hits.toString());
