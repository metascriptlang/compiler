// @xfail(raiser): the Raiser VM answers indexOf with an empty needle differently (prints '10 1 -4 0' where C and JS print '3 1 0 0')
function run(): void {
	const s: string = "abc";
	console.log(`${s.indexOf("", 10)} ${s.indexOf("", 1)} ${s.indexOf("", -4)} ${s.indexOf("")}`);
	console.log(`${s.lastIndexOf("", 1)} ${s.lastIndexOf("", 9)} ${s.lastIndexOf("")}`);
	const t: string = "héllo";
	console.log(`${t.indexOf("", 6)} ${t.indexOf("", 5)} ${t.lastIndexOf("", 2)} ${t.lastIndexOf("")}`);
	const u: string = "a😀b";
	console.log(`${u.indexOf("", 9)} ${u.lastIndexOf("", 3)} ${u.indexOf("b")} ${u.lastIndexOf("a", 3)}`);
}

run();
