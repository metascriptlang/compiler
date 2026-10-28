// @stdout: sync|a|then|b|nested|timer
// @exit: 0
// @skip-raiser: no host timers on raiser
const order: string[] = [];
queueMicrotask((): void => { order.push("a"); });
Promise.resolve(1).then((v: int32): void => { order.push("then"); });
queueMicrotask((): void => {
	order.push("b");
	queueMicrotask((): void => { order.push("nested"); });
});
setTimeout((): void => { order.push("timer"); console.log(order.join("|")); }, 0);
order.push("sync");
