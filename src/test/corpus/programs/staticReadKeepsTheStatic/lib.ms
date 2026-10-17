export type Ease = (t: number) => number;
function linearCurve(t: number): number { return t; }
export class Curves {
	static linear: Ease = linearCurve;
}
export let shared: string[] = ["lib"];
export let defaultEase: Ease = linearCurve;
