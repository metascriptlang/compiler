// A Promise<never> value meets a promise of any payload as an argument, a return and a declaration.
// @stdout: arg|call|var|point|done

@passC("-Werror=incompatible-pointer-types");

struct Point { x: int32; y: int32; }

function never(m: string): Promise<never> { return Promise.reject(new Error(m)); }
function hold(p: Promise<string>): Promise<string> { return p; }
function holdPoint(p: Promise<Point>): Promise<Point> { return p; }
function viaVar(): Promise<int32> { const r = never("var"); return r; }

async function run(): Promise<void> {
	let log = "";
	try { log += await hold(Promise.reject(new Error("arg"))); } catch (e) { log += `${e.message}|`; }
	try { log += await hold(never("call")); } catch (e) { log += `${e.message}|`; }
	try { log += `${await viaVar()}`; } catch (e) { log += `${e.message}|`; }
	try { log += `${(await holdPoint(never("point"))).x}`; } catch (e) { log += `${e.message}|`; }
	console.log(log + "done");
}
run();
