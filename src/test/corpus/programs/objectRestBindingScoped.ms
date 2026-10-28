// @stdout: s10 s11 s12 | s1s1 | s1 | 2 7
// note: the object a rest pattern binds is fresh, so a loop, an array that holds it, an alias and a return each release it once on every lane, whether its fields are strings or plain data.
interface Tagged { count: int32; label: string; }
interface Plain { n: int32; m: int32; }

function loop(b: Tagged): string {
	let seen = "";
	for (let i = 0; i < 3; i++) {
		const { count, ...rest } = b;
		seen += (i > 0 ? " " : "") + rest.label + String(i);
	}
	return seen;
}

function held(b: Tagged): string {
	const { count, ...rest } = b;
	const all = [rest];
	const again = rest;
	return all[0].label + again.label;
}

function returned(b: Tagged): string {
	const { count, ...rest } = b;
	return rest.label;
}

function plain(p: Plain): string {
	const { n, ...rest } = p;
	return `${n} ${rest.m}`;
}

const tagged: Tagged = { count: 3, label: "s" + String(1) };
console.log(`${loop(tagged)} | ${held(tagged)} | ${returned(tagged)} | ${plain({ n: 2, m: 7 })}`);
