// @stdout: 65 true 1
// @stdout: 100 true 2
// @stdout: narrow true false
// @exit: 0
enum Small { A, B, C }
enum Pair { X, Y }
enum Flag65 {
	F0, F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12, F13, F14, F15,
	F16, F17, F18, F19, F20, F21, F22, F23, F24, F25, F26, F27, F28, F29, F30, F31,
	F32, F33, F34, F35, F36, F37, F38, F39, F40, F41, F42, F43, F44, F45, F46, F47,
	F48, F49, F50, F51, F52, F53, F54, F55, F56, F57, F58, F59, F60, F61, F62, F63,
	F64,
}
enum Flag100 {
	F0, F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12, F13, F14, F15,
	F16, F17, F18, F19, F20, F21, F22, F23, F24, F25, F26, F27, F28, F29, F30, F31,
	F32, F33, F34, F35, F36, F37, F38, F39, F40, F41, F42, F43, F44, F45, F46, F47,
	F48, F49, F50, F51, F52, F53, F54, F55, F56, F57, F58, F59, F60, F61, F62, F63,
	F64, F65, F66, F67, F68, F69, F70, F71, F72, F73, F74, F75, F76, F77, F78, F79,
	F80, F81, F82, F83, F84, F85, F86, F87, F88, F89, F90, F91, F92, F93, F94, F95,
	F96, F97, F98, F99,
}

const wide65: [BitSet<Flag65>, int32] = [(0 as BitSet<Flag65>).incl(Flag65.F64), 1];
const wide100: [BitSet<Flag100>, int32] = [(0 as BitSet<Flag100>).incl(Flag100.F99), 2];
console.log(65, wide65[0].has(Flag65.F64), wide65[1]);
console.log(100, wide100[0].has(Flag100.F99), wide100[1]);

const narrow: [BitSet<Small>, BitSet<Pair>][] = [[(0 as BitSet<Small>).incl(Small.C), (0 as BitSet<Pair>).incl(Pair.X)]];
console.log("narrow", narrow[0][0].has(Small.C), narrow[0][1].has(Pair.Y));
