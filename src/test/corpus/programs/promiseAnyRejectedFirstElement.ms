// @stdout: 6
// @stdout: ok
// @stdout: 6
// @stdout: 7
// @stdout: w
// @stdout: w

async function six(): Promise<int32> {
	return 6;
}

async function word(): Promise<string> {
	return "w";
}

async function ok(): Promise<string> {
	return "ok";
}

console.log(await Promise.any([Promise.reject("no"), six()]));
console.log(await Promise.any([Promise.reject("no"), ok()]));
console.log(await Promise.any([six(), Promise.reject("no")]));
console.log(await Promise.any([Promise.reject("a"), Promise.reject("b"), six()]) + 1);
console.log(await Promise.any([word(), six()]));
console.log(await Promise.any([Promise.reject("no"), word(), six()]));
