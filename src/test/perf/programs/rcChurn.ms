import { argv } from "std/process";

class Leaf { value: int32 = 0; }
class Pair { left: Leaf | null = null; right: Leaf | null = null; }

function churn(rounds: int32): int64 {
	const shared = new Leaf();
	let sum: int64 = 0;
	for (let i: int32 = 0; i < rounds; i++) {
		const p = new Pair();
		p.left = shared;
		p.right = shared;
		shared.value = i;
		sum += p.left!.value + p.right!.value;
	}
	return sum;
}

const rounds: int32 = argv.length > 1 ? argv[1].parseInt() as int32 : 2000000;
console.log(`rcChurn ${churn(rounds)}`);
