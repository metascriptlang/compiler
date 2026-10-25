// @stdout: early **=: caught
// @stdout: early +=: caught
// @stdout: early <<=: caught
// @stdout: late: 9 5 12
function pow(): void { power **= 2; }
function add(): void { total += 2; }
function shift(): void { bits <<= 2; }
try { pow(); console.log("early **=: wrote"); } catch (e) { console.log("early **=: caught"); }
try { add(); console.log("early +=: wrote"); } catch (e) { console.log("early +=: caught"); }
try { shift(); console.log("early <<=: wrote"); } catch (e) { console.log("early <<=: caught"); }
export let power: int32 = 3;
export let total: int32 = 3;
export let bits: int32 = 3;
pow();
add();
shift();
console.log(`late: ${power} ${total} ${bits}`);
