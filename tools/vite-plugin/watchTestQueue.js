export function watchTestQueue() {
 const queued = [];
 let waiting;
 return {
  push(value) { if (waiting) { const resolve = waiting; waiting = null; resolve(value); } else queued.push(value); },
  next() { return queued.length ? Promise.resolve(queued.shift()) : new Promise(resolve => { waiting = resolve; }); },
  get pending() { return queued.length; },
 };
}
