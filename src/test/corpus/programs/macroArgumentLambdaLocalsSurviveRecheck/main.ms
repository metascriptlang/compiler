// @stdout: 3 4 5 3 3 3 9
// @exit: 0
// note: a lambda written as a macro argument keeps working after the macro hands it back. A destructured local (array, object, for-of pattern) is redeclared by the re-check, so a read of it must not stay pinned to the first check's symbol, at any lambda depth. A generic call with an explicit type argument inside it is pinned to the generic it names, not to the instance the first check chose, so the re-check made while the enclosing generic call infers its props type instantiates it again.
import { same, mount, mountWith } from "./macros";
import { box } from "./box";

interface RowProps { renderItem: (i: number) => number; }
function Row(props: RowProps): number { return props.renderItem(1); }

const arrayPattern = same((i: number): number => { const [a, b] = [i, i + 1]; return a + b; });
const objectPattern = same((i: number): number => { const { p, q } = { p: i, q: i + 2 }; return p + q; });
const forOfPattern = same((i: number): number => {
	let total: number = 0;
	for (const [k, v] of [[i, 1], [i, 2]]) { total += k + v; }
	return total;
});
const nested = same((i: number): number => same((j: number): number => { const [a, b] = [j, i]; return a + b; })(i + 1));
const generic = mountWith(Row, (i: number): number => { const s = box<number>(i + 2); return s[0](); });
const genericNested = mountWith(Row, (i: number): number => {
	const inner = same((j: number): number => { const [on] = box<number>(j); return on() + 1; });
	return inner(i + 1);
});
const both = mountWith(Row, (i: number): number => { const [a, b] = [i, box<number>(i + 6)[0]()]; return a + b + 1; });

console.log(`${arrayPattern(1)} ${objectPattern(1)} ${forOfPattern(1)} ${nested(1)} ${generic} ${genericNested} ${both}`);
