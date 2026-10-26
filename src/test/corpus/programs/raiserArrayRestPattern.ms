// @stdout: a bc 2 d
// @stdout: 1 3 2 30
// @stdout: x 0 empty
// note: an array rest pattern copies the tail into a new array: string and struct elements, a source changed afterwards, a one-element source and a rest-only pattern
struct P { x: int32; }

function tailSize(names: string[]): number {
	const [first, ...rest] = names;
	return rest.length;
}

const words: string[] = ["a", "b", "c"];
const [head, ...others] = words;
words[1] = "d";
console.log(head, others.join(""), others.length, words[1]);

const points: P[] = [{ x: 1 }, { x: 2 }, { x: 3 }];
const [p0, ...ps] = points;
points[1] = { x: 30 };
console.log(p0.x, ps[1].x, ps.length, points[1].x);

const lone: string[] = ["x"];
const [only, ...none] = lone;
console.log(only, none.length, tailSize(["q", "r"]) == 1 ? "empty" : "wrong");
