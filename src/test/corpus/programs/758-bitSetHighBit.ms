// Parity program — the highest bit of a `BitSet<E>`. A 32-member enum puts a
// member at ordinal 31, so the member-to-bit shift has to be unsigned: `1 << 31`
// on a signed word is undefined and traps under the checked build.
//
// @stdout: true,true,false,true,true,false,true
// @exit: 0

enum Wide { M0, M1, M2, M3, M4, M5, M6, M7, M8, M9, M10, M11, M12, M13, M14, M15, M16, M17, M18, M19, M20, M21, M22, M23, M24, M25, M26, M27, M28, M29, M30, M31 }

function main(): void {
	const hi: BitSet<Wide> = Wide.M30 | Wide.M31;
	const lo = hi.incl(Wide.M0).excl(Wide.M31);
	const drained = hi.excl(Wide.M30).excl(Wide.M31);
	console.log(`${hi.has(Wide.M30)},${hi.has(Wide.M31)},${hi.has(Wide.M29)},${lo.has(Wide.M0)},${lo.has(Wide.M30)},${lo.has(Wide.M31)},${drained.isEmpty()}`);
}
main();
