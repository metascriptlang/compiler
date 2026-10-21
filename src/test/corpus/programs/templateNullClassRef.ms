// @stdout: null
// @stdout: v=null!
// @stdout: null
// @stdout: null
// @stdout: null
// @stdout: {"n":1}|{"n":1}|{"n":1}|v={"n":1}!
class Box { n: number = 1; }
interface Named { a: int32; }
const none: Box | null = null;
console.log(`${none}`);
console.log(`v=${none}!`);
console.log(String(none));
console.log(none);
const noName: Named | null = null;
console.log(`${noName}`);
const live: Box | null = new Box();
console.log(`${live}|${String(live)}|${live.toString()}|v=${live}!`);
