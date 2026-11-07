# goose-process

[![ci](https://github.com/rekanalar/goose-process/actions/workflows/ci.yml/badge.svg)](https://github.com/rekanalar/goose-process/actions/workflows/ci.yml)

Start a program from Goose. Hold a live handle of it. Read what it prints
while it prints. Keep the two streams apart. Chain one child into the next.

Feed it input. Set its environment and its directory. Stop it on a timeout.
The package is a stopgap. Drop it when the standard library has the same
functions.

## Install

Add this to the root file of the program that uses it:

```goose
import process from "rekanalar/goose-process@v1.0.0";
```

The CI runs the gate on Linux, on macOS and on Windows. It uses Goose
v2026.3 and v2026.4 on each.

## What changed in v0.2.0

v0.1.x started a program and waited for it. v0.2.0 adds the live handle:
`spawn`, `alive`, `read`, `write`, `close_input`, `wait`, `kill` and `free`.
It adds `RUNNING` as a status. It adds `separate` to `Options`, and the
apart run `run_split`.

Nothing of v0.1.x changed its name, its type or its result. One rule is
new: `run` refuses a request that sets `separate`. Use `run_split` when you
want the two streams apart.

## Parity with the reference libraries

The package holds the features of Python `subprocess`, Rust
`std::process::Command`, Go `os/exec` and Node `child_process`.

| Reference | Here |
|---|---|
| Python `run`, Go `Run` | `run` |
| Python `capture_output`, Go `CombinedOutput` | `run` (joined), `run_split` (apart) |
| Python `input`, Go `Cmd.Stdin` | the `input` argument, and `write` with `close_input` |
| Python `env` and `cwd` | `Options.env` and `Options.cwd` |
| Python `timeout`, Go `CommandContext` | `Options.timeout_ms`, `wait` with a limit |
| Python `Popen`, Rust `spawn`, Go `Start` | `spawn` |
| Python `poll`, Rust `try_wait` | `alive` |
| Python `wait`, Rust `wait`, Go `Wait` | `wait` |
| Python `kill`, Rust `kill`, Go `Process.Kill` | `kill`, `free` |
| Node `spawn` streams | `read` in a loop |
| A pipe between two children | a copy through the caller (`examples/chain.goose`) |

These gaps stay on purpose:

- The stop is always a kill. Node `killSignal` and Python `terminate` have
  no match here.
- Python `check` has no match. Test `status` and `code` after the wait.
- The chain copies the bytes through the caller. No pipe object joins two
  children.
- The package starts no shell.

## This package is a stopgap

The Goose compiler already starts programs. It does it in C over the header
`subprocess.h`. No Goose program can reach that code.

The standard library has no module that starts a program. Ask the compiler
project for one. When it ships, drop this package.

The API stays close to the shape that such a module would take. A program
moves over with few edits.

## Use

Give the name of a program and a list of arguments. The package starts the
program and waits for it.

```goose
import std;
import process from "rekanalar/goose-process@v1.0.0";

fn main() {
    var args: const u8[:][>..] = [];
    args.push("-l");

    var opts = process::options();
    opts.timeout_ms = 5000;

    let r = process::run("ls", args, "", opts);
    if r.status != process::ENDED {
        exit(1);
    }
    print(r.output);
    return 0;
}
```

See `examples/hello.goose` for a complete program.

## A live child

`spawn` starts a program and returns at once. The handle answers whether
the child lives, and it takes the bytes that arrived.

```goose
let child = process::spawn("sh", args, opts);
var text: u8[>..] = [];
var errors: u8[>..] = [];
while process::alive(child) {
    process::read(child, text, errors);
}
let outcome = process::wait(child, 5000);
process::read(child, text, errors);
process::free(child);
```

`read` moves the bytes that arrived since the last read. It returns at once
when no bytes wait. `wait` drains the pipes, so a read after the wait holds
every byte. `free` stops a child that still lives, so no orphan stays
behind. See `examples/live.goose`.

## A chain of two children

The caller copies the bytes. No shell runs between the two children.

```goose
let first = process::spawn("sh", first_args, opts);
while process::alive(first) {
    process::read(first, text, errors);
}
process::wait(first, 0);

let second = process::spawn("sh", second_args, opts);
process::write(second, text);
process::close_input(second);
while process::alive(second) {
    process::read(second, answer, errors);
}
process::wait(second, 5000);
process::free(first);
process::free(second);
```

`write` waits while the child does not take the bytes. Start the second
child only when you know that it reads its input. See
`examples/chain.goose`.

## API

| Function | Purpose |
|---|---|
| `process::options()` | Return an `Options` with the defaults. |
| `process::run(cmd, args, input, opts)` | Start the program `cmd` with the arguments `args`. Write `input` to its standard input. Wait for it. Return a `Result`. The streams stay joined. Refuses `separate`. |
| `process::run_split(cmd, args, input, opts, out, err)` | Start the program and wait for it. Keep the output stream and the error stream apart. Return an `Outcome`. |
| `process::spawn(cmd, args, opts)` | Start the program without waiting. Return a `Child`. |
| `process::alive(child)` | Say whether the child still lives. |
| `process::read(child, out, err)` | Move the bytes that arrived since the last read into `out` and `err`. Return the count. |
| `process::write(child, bytes)` | Give bytes to the input of the child. Wait while the child does not take them. Return the count. |
| `process::close_input(child)` | Close the input of the child. The child sees the end of its input. |
| `process::wait(child, timeout_ms)` | Wait for the child. A limit of 0 waits without a limit. Return an `Outcome`. |
| `process::kill(child)` | Stop the child. The stop stays a kill. |
| `process::free(child)` | Stop a child that lives, then free the handle. |

`cmd` is the name of the program. It is the first argument of the child.
`args` holds the other arguments. `input` holds the bytes for the standard
input of the child. `opts` holds the settings.

### The statuses

| Constant | Value | Meaning |
|---|---|---|
| `process::ENDED` | 0 | The child ran and ended. The code holds its exit code. |
| `process::NOT_STARTED` | 1 | The child did not start. The program does not exist, or the directory is bad. |
| `process::STOPPED` | 2 | The child was stopped on the time limit, or the caller stopped it. |
| `process::REFUSED` | 3 | The package refused the request. It started no program. |
| `process::RUNNING` | 4 | The child lives. A `Child` holds it until it ends. |

### Options

| Field | Type | Meaning |
|---|---|---|
| `cwd` | `u8[..255]` | The working directory of the child. Empty means the directory of the parent. |
| `timeout_ms` | `i32` | The time limit in milliseconds. 0 means no limit. |
| `separate` | `bool` | The output stream and the error stream stay apart. `run` refuses it. `run_split` and `spawn` honor it. |
| `env` | `const u8[:][>..]` | The entries to set or to change. Each entry is `NAME=VALUE`. Empty means the environment of the parent. |

A variable that the caller does not set keeps the value of the parent.

### Result

| Field | Type | Meaning |
|---|---|---|
| `status` | `i32` | One of the four statuses. |
| `code` | `i32` | The exit code of the child. It has no meaning when the child was stopped. |
| `output` | `u8[>..]` | The standard output and the standard error of the child, joined. |

### Child

| Field | Type | Meaning |
|---|---|---|
| `id` | `i32` | The handle of the child. Below zero when it did not start. |
| `status` | `i32` | `RUNNING`, `NOT_STARTED`, `STOPPED` or `REFUSED`. |

### Outcome

| Field | Type | Meaning |
|---|---|---|
| `status` | `i32` | `ENDED`, `STOPPED` or `NOT_STARTED`. |
| `code` | `i32` | The exit code of the child. It has no meaning when the child was stopped. |

## The C part

The package wraps one C header. The header is `subprocess.h` of sheredom,
under the Unlicense. It sits under `vendor/`. The Goose compiler ships the
same header in `third_party/subprocess/`.

The C layer of this package sits in `src/proc.c`. It takes one flat byte
buffer. The buffer holds the arguments, the environment and the directory.
Each C function has at most five argument slots. That stays safe on the
TinyCC JIT of macOS and arm64.

The live child holds a table of 16 slots in the same C file. Each call
carries the number of its slot. The layer reads the pipes of a child at
every call. A child that writes much never waits for the parent.

The C part needs a C compiler. `goose build` and `goose run` build it into
the program.

## Limits that stay

- The output grows with the output of the child. The caller sets a limit to
  bound it.
- The stop is a kill. No child can refuse it. The kill reaches the child
  only. The grandchildren of the child stay.
- A child that dies from a signal gives the code 1. The package cannot
  tell it from a program that ended with the code 1.
- The directory of the child needs a system that can set it. That is glibc
  from 2.29, macOS from 10.15 and Windows. The directory holds at most 255
  bytes.
- The child gets at most 64 arguments. The name of the program is one of
  them.
- The environment holds at most 256 entries.
- The package finds the program with the PATH of the parent. A PATH in the
  environment of the child does not change that.
- An environment entry needs an equals sign. An entry without one is
  refused.
- A NUL byte in an argument cuts the argument at that byte. The operating
  system cannot pass a NUL byte in an argument.
- The package starts no shell. An argument reaches the child as one
  argument.
- A timed run on Windows returns after the kill now. On v0.1.0 it could
  hang when a grandchild held the input pipe of the child.
- The rare write from the parent, when the writer thread does not start,
  stays blocking on Windows.

## Limits of the live child

- The table holds 16 children at the same time. A start that finds no slot
  is refused. A free makes room.
- A start failure comes at once. A program that does not exist gives
  `NOT_STARTED` from `spawn`.
- The write of the input runs in the thread of the caller. It waits while
  the child does not take the bytes. Start a child that reads its input,
  or close the input early. The one-shot `run` keeps its own writer thread
  and does not wait.
- The chain copies the bytes through the caller. The package holds no pipe
  object between two children.
- The read never blocks, but it returns only the bytes that have arrived.
  It does not wait for more.
- `run_split` keeps its time limit while it writes the input. The plain
  `write` has no limit.
- A `Child` holds a slot number only. After `free`, a copy of the `Child`
  can reach a new child in the same slot. Drop the copy at `free`.
- The handle calls use one global table with no lock. Call them from one
  thread.
- The package holds the bytes of a child until the caller reads them. A
  child that writes without end and a caller that never reads fill the
  memory.
- A copy of a struct with a growable field shares the buffer of that
  field. Build a new `Options` instead of copying one.

## Not verified

- The quoting of arguments on Windows beyond the tests of this package.
- A child that ignores the stop signal. The test runs on Unix only.
- The grandchildren of a child.
- The cancel of a blocked write on Windows. No machine of this project
  runs Windows. The CI runs the suite there on every push.
- The live child on Windows beyond the CI suite. The paths of the pipes
  and the kill differ there.

## Test

```sh
TMPDIR=/some/scratch bash run-gate.sh /path/to/goose-release
```

The gate checks the entry file, then runs and builds the tests and each
example. Run it once for each compiler.

## License

MIT
