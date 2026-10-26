// @stdout: 50 -2000000 2900000 22500000
// @stdout: -128 -100 123 -111
// @stdout: 17 4000000000 3999999965 3999999867
// @stdout: 300 253 129 -30000 28000 -22000,-20000,-18000
// @stdout: 10.25 215 8 10
// Arrays of narrow integers and float32 keep their element width in VM memory: sign and zero extension, wraparound, growth, removal and copy give the same output on C and on the Raiser VM.

function main(): void {
	const a: int32[] = [];
	for (let i = 0; i < 50; i += 1) a.push((i * 100000 - 2000000) as int32);
	let sa: number = 0;
	for (let i = 0; i < a.length; i += 1) sa += a[i];
	console.log(`${a.length} ${a[0]} ${a[49]} ${sa}`);
	const b: int8[] = [];
	for (let i = 0; i < 40; i += 1) b.push(((i * 13) % 256 - 128) as int8);
	b[3] = -100 as int8;
	let sb: number = 0;
	for (let i = 0; i < b.length; i += 1) sb += b[i];
	console.log(`${b[0]} ${b[3]} ${b[39]} ${sb}`);
	const u: uint32[] = [];
	for (let i = 0; i < 20; i += 1) u.push((4000000000 - i * 7) as uint32);
	u.splice(2, 3);
	console.log(`${u.length} ${u[0]} ${u[2]} ${u[16]}`);
	const h: uint8[] = [];
	for (let i = 0; i < 300; i += 1) h.push((i * 3) as uint8);
	const c: int16[] = [];
	for (let i = 0; i < 30; i += 1) c.push((i * 2000 - 30000) as int16);
	console.log(`${h.length} ${h[255]} ${h[299]} ${c[0]} ${c[29]} ${c.slice(4, 7).join(",")}`);
	const f: float32[] = [];
	for (let i = 0; i < 40; i += 1) f.push((i * 0.25 + 0.5) as float32);
	let sf: number = 0;
	for (let i = 0; i < f.length; i += 1) sf += f[i];
	const g = f.slice(30);
	console.log(`${f[39]} ${sf} ${g[0]} ${g.length}`);
}

main();
