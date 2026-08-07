# Zelky - interpreted bytecode vm based toy language written in Zig

Zelky is a interpreted language written in Zig from scratch made as an exercise for learning Zig.

## Example code

```
func fib(n) {
 if (n <= 1) {
  return n; 
 }
 return fib(n - 1) + fib(n - 2);
}

return fib(40);
```

## To-Do list

- [x] Constants
- [x] Globals
- [x] Variables
- [x] Functions
  - [ ] Closures
- [ ] Control flow
  - [x] return statements
  - [x] if/else statements
  - [x] for/while statements
    - [ ] continue/break statements
- [ ] Strings
- [ ] Lists/Arrays
- [ ] Structs
- [ ] Enums
- [ ] Unions
- [ ] REPL (as of right now, the code to be executed (source code only, not bytecode) is compiled with the bianry)
- [ ] And more... (standard library, modules etc.)

## Build instructions

Built on Zig version 0.16.0

```
git clone https://github.com/SzymonJaroslawski/zelky
cd zelky
zig build
```

## Benchmark

In it current state the ```fib()``` function from example code executes **~2.0 seconds** faster than equivalent code in Python (3.14.6) with Zelky taking around 8 seconds where as Python takes around 10 seconds.
The benchmarks where done using Hyperfine with warm up of 10.
To be fair, this is a result of implementing specific superinstructions (super opcodes) in the Zelky VM that are particularly helpful for this example. This benchmark is of course purely synthetic and not really representative of the real world performance (if you can even say "real world" as Zelky can't yet interact with the machine in any useful way.)

## License

MIT
