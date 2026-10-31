import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const [dir, bundle] = process.argv.slice(2);
if (!dir || !bundle) throw new Error('usage: node slotTable.mjs <dir> <bundle.js>');
const text = readFileSync(resolve(dir, bundle), 'utf8');
const open = text.indexOf('const __msb = (() => {');
const close = text.indexOf('})();', open);
if (open < 0 || close < 0) throw new Error('slotTable: the bundle carries no __msb registry');
const source = text.slice(open, close + 5);
const fresh = () => new Function(source + '\nreturn __msb;')();

const check = (ok, what) => {
	if (!ok) throw new Error('slotTable: ' + what);
};
const throwsWith = (fn, part, what) => {
	let seen = null;
	try {
		fn();
	} catch (e) {
		seen = e;
	}
	check(seen !== null, what + ': did not throw');
	check(String(seen.message).includes(part), what + ': threw ' + JSON.stringify(String(seen.message)) + ', wanted ' + JSON.stringify(part));
	return seen;
};
const slotOf = (id) => id & 0xffff;

{
	const r = fresh();
	const fa = () => 1, fb = () => 2, fc = () => 3;
	const a = r.push(fa), b = r.push(fb), c = r.push(fc);
	check(new Set([slotOf(a), slotOf(b), slotOf(c)]).size === 3, 'three live entries share a slot');
	check(r.cb(a) === fa && r.cb(b) === fb && r.cb(c) === fc, 'cb does not return the pushed function');
	r.pop(c);
	r.pop(b);
	const d = r.push(() => 4), e = r.push(() => 5);
	check(slotOf(d) === slotOf(b), 'the slot released last is not reused first');
	check(slotOf(e) === slotOf(c), 'the slot released first is not reused second');
	check(slotOf(r.push(() => 6)) !== slotOf(a), 'a live slot was handed out again');
}

{
	const r = fresh();
	const id = r.push(() => 1);
	r.pop(id);
	throwsWith(() => r.pop(id), 'boundary entry released twice', 'double pop');
	throwsWith(() => r.cb(id), 'callback used after its call returned', 'cb after pop');
}

{
	const r = fresh();
	const f1 = () => 1, f2 = () => 2;
	const x = r.push(f1);
	r.pop(x);
	const y = r.push(f2);
	check(slotOf(x) === slotOf(y), 'the released slot was not reused');
	check(x !== y, 'a reused slot kept its id');
	throwsWith(() => r.cb(x), 'callback used after its call returned', 'stale id after slot reuse');
	throwsWith(() => r.pop(x), 'boundary entry released twice', 'stale pop after slot reuse');
	check(r.cb(y) === f2, 'a stale pop disturbed the live entry');
	r.pop(y);
}

{
	const r = fresh();
	const f = () => 0;
	const first = r.push(f);
	r.pop(first);
	let wrapped = -1;
	for (let i = 1; i <= 33000; i++) {
		const id = r.push(f);
		check(Number.isInteger(id) && id >= 0 && id <= 0x7fffffff && (id | 0) === id, 'id ' + id + ' at cycle ' + i + ' is not a non-negative int32');
		check(r.cb(id) === f, 'cb at cycle ' + i);
		r.pop(id);
		if (id === first && wrapped < 0) wrapped = i;
	}
	check(wrapped === 32768, 'the id of one slot first repeats after ' + wrapped + ' reuses, not 32768');
}

{
	const r = fresh();
	const f = () => 0;
	const ids = [];
	for (let i = 0; i < 65536; i++) ids.push(r.push(f));
	throwsWith(() => r.push(f), 'boundary table full: 65536 live entries', 'push past the cap');
	r.pop(ids.pop());
	check(typeof r.push(f) === 'number', 'a released entry did not make room');
}
