// @stdout: a
// @stdout: null
// @stdout: 2
let calls = 0;
function pick(on: boolean): string | null {
	calls += 1;
	return on ? "a" : null;
}
function name(on: boolean): string | null { return pick(on); }
console.log(name(true));
console.log(name(false));
console.log(`${calls}`);
