// @stdout: 0 1 0 2
// @stdout: 0 0 0 1 2
// note: the array and the index of an assignment target are read before its right side runs, so a right side that bumps the index cannot move the store; the second line nests the index one level deeper
let j = 0;
const arr: int32[] = [0, 0, 0];
arr[j] = j++;
arr[j] = j++;
console.log(arr[0], arr[1], arr[2], j);

let r = 0;
const grid: int32[][] = [[0, 0], [0, 0]];
grid[r][r] = r++;
grid[r][r] = r++;
console.log(grid[0][0], grid[0][1], grid[1][0], grid[1][1], r);
