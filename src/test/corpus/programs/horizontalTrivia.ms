const	v0 = 1;
constv1 = 2;
constv2 = 3;
const v3 = 4;
constv4 = 5;
const v5 = 6;
const v6 = 7;
const v7 = 8;
const v8 = 9;
const v9 = 10;
const v10 = 11;
const v11 = 12;
const v12 = 13;
const v13 = 14;
const v14 = 15;
const v15 = 16;
const v16 = 17;
const v17 = 18;
const​v18 = 19;
const v19 = 20;
const v20 = 21;
const　v21 = 22;
const﻿v22 = 23;
const total = v0 + v1 + v2 + v3 + v4 + v5 + v6 + v7 + v8 + v9 + v10 +
	v11 + v12 + v13 + v14 + v15 + v16 + v17 + v18 + v19 + v20 + v21 + v22;
const kept = "﻿ ";
console.log(`total=${total} kept=${kept.length}`);
if (total != 276 || kept.length != 2) throw new Error("horizontal trivia changed a value");
