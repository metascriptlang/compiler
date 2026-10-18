// @xfail(raiser): raiser runtime error: Unknown host function: msFutureThen
// @stdout: fresh 4
// @stdout: local 5 5
// @stdout: held 6 6
// @stdout: then 7
// @stdout: generic 9
// @stdout: top 8 9
// @stdout: done
// note: Promise.resolve(object) makes a promise that owns the object, as an async function's
// result does: a fresh object, an existing local the caller keeps reading, one promise awaited
// twice, a then callback, a generic caller and top-level await all read a live object. Before the
// future owned its value, C freed the object at the end of the resolving statement and the await
// read it after free (ASan heap-use-after-free with the slab off).

class Plain { n: int32 = 4; }

function made(n: int32): Plain {
	const p = new Plain();
	p.n = n;
	return p;
}

async function wrap<T>(v: T): Promise<T> {
	return await Promise.resolve(v);
}

async function readAll(): Promise<void> {
	const plain = await Promise.resolve(new Plain());
	console.log(`fresh ${plain.n}`);

	const kept = made(5);
	const same: Plain = await Promise.resolve(kept);
	console.log(`local ${same.n} ${kept.n}`);

	const pr = Promise.resolve(made(6));
	const a = await pr;
	const b = await pr;
	console.log(`held ${a.n} ${b.n}`);

	await Promise.resolve(made(7)).then((p: Plain): void => { console.log(`then ${p.n}`); });

	const g = await wrap(made(9));
	console.log(`generic ${g.n}`);
}

await readAll();
const top = await Promise.resolve(made(8));
const again = await wrap(made(9));
console.log(`top ${top.n} ${again.n}`);
console.log("done");
