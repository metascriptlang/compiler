const values: number[] = [];
for (let i: number = 0; i < 300000; i += 1) values.push((i * 7919) % 300007);
let sum: number = 0;
for (let i = 0; i < values.length; i += 1) sum += values[i] % 13;
values.sort();
console.log(`array ${sum} ${values[0]} ${values[values.length - 1]} ${values[150000]}`);
