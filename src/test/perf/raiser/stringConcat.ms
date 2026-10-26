let total = 0;
let acc = "";
for (let i = 0; i < 200000; i += 1) {
	const part = `item-${i}:${i * 3}`;
	acc = acc + part + ";";
	if (acc.length > 4000) {
		total += acc.length;
		acc = "";
	}
}
let joined = "";
for (let i = 0; i < 3000; i += 1) joined += "ab";
console.log(`strings ${total + acc.length + joined.length}`);
