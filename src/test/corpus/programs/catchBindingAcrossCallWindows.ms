// @stdout: module 15 deeper 6
// note: a catch binding at module level lies inside the register window a later call and its own callees reuse, so the frame overlay releases the shell it holds before the callee's own registers are cleared.

function th(i: int32): void { throw "x" + i.toString(); }
function thObject(i: int32): void { throw new Error("y" + i.toString()); }

let caught = 0;
for (let i: int32 = 0; i < 5; i += 1) {
	try { th(i); } catch (e) { caught += 1; }
	try { th(i); } catch (e) { caught += 1; }
	try { th(i); } catch (e) { caught += 1; }
}
let deeper = 0;
let j: int32 = 0;
while (j < 2) {
	j += 1;
	try { thObject(j); } catch (e) { deeper += 1; }
	try { thObject(j); } catch (e) { deeper += 1; }
	try { thObject(j); } catch (e) { deeper += 1; }
}
console.log(`module ${caught} deeper ${deeper}`);
