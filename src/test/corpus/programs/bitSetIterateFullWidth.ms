// @xfail(raiser): the Raiser VM prints an enum member as its ordinal ('0,1,2,3,4,5,6,7|1,15|…'), as in 775-bitSetIterate
// @stdout: M0,M1,M2,M3,M4,M5,M6,M7|N1,N15|O0,O31|Q0,Q63|Y0,Y71|R8|A,C|{A, C}
// @exit: 0

enum M { M0, M1, M2, M3, M4, M5, M6, M7 }
enum N { N0, N1, N2, N3, N4, N5, N6, N7, N8, N9, N10, N11, N12, N13, N14, N15 }
enum O { O0, O1, O2, O3, O4, O5, O6, O7, O8, O9, O10, O11, O12, O13, O14, O15, O16, O17, O18, O19, O20, O21, O22, O23, O24, O25, O26, O27, O28, O29, O30, O31 }
enum Q { Q0, Q1, Q2, Q3, Q4, Q5, Q6, Q7, Q8, Q9, Q10, Q11, Q12, Q13, Q14, Q15, Q16, Q17, Q18, Q19, Q20, Q21, Q22, Q23, Q24, Q25, Q26, Q27, Q28, Q29, Q30, Q31, Q32, Q33, Q34, Q35, Q36, Q37, Q38, Q39, Q40, Q41, Q42, Q43, Q44, Q45, Q46, Q47, Q48, Q49, Q50, Q51, Q52, Q53, Q54, Q55, Q56, Q57, Q58, Q59, Q60, Q61, Q62, Q63 }
enum Y { Y0, Y1, Y2, Y3, Y4, Y5, Y6, Y7, Y8, Y9, Y10, Y11, Y12, Y13, Y14, Y15, Y16, Y17, Y18, Y19, Y20, Y21, Y22, Y23, Y24, Y25, Y26, Y27, Y28, Y29, Y30, Y31, Y32, Y33, Y34, Y35, Y36, Y37, Y38, Y39, Y40, Y41, Y42, Y43, Y44, Y45, Y46, Y47, Y48, Y49, Y50, Y51, Y52, Y53, Y54, Y55, Y56, Y57, Y58, Y59, Y60, Y61, Y62, Y63, Y64, Y65, Y66, Y67, Y68, Y69, Y70, Y71 }
enum R { R0, R1, R2, R3, R4, R5, R6, R7, R8 }
enum P { A = 0, B = 1, C = 2 }

function names<T>(items: T[]): string {
	const out: string[] = [];
	for (const it of items) { out.push(it.toString()); }
	return out.join(",");
}

function main(): void {
	const full: BitSet<M> = M.M0 | M.M1 | M.M2 | M.M3 | M.M4 | M.M5 | M.M6 | M.M7;
	let viaForOf = "";
	for (const m of full) {
		if (viaForOf != "") { viaForOf = viaForOf + ","; }
		viaForOf = viaForOf + m.toString();
	}
	const n16: BitSet<N> = N.N1 | N.N15;
	const n32: BitSet<O> = O.O0 | O.O31;
	const n64: BitSet<Q> = Q.Q0 | Q.Q63;
	const n72: BitSet<Y> = Y.Y0 | Y.Y71;
	const nine: BitSet<R> = (0 as BitSet<R>).incl(R.R8);
	const explicit: BitSet<P> = P.A | P.C;
	const parts: string[] = [
		viaForOf,
		names(n16.toItems()),
		names(n32.toItems()),
		names(n64.toItems()),
		names(n72.toItems()),
		names(nine.toItems()),
		names(explicit.toItems()),
		explicit.toString(),
	];
	console.log(parts.join("|"));
}
main();
