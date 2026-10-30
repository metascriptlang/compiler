// @stdout: true true 4
when (js) {
	class Clock {
		static extern stamp(): number from "Date.now";
		static extern abs(x: number): number from "Math.abs";
	}
	extern function stampFree(): number from "Date.now";
	console.log(stampFree() > 0, Clock.stamp() > 0, Clock.abs(-4));
} else {
	console.log("true true 4");
}
