# goose-process

[![ci](https://github.com/rekanalar/goose-process/actions/workflows/ci.yml/badge.svg)](https://github.com/rekanalar/goose-process/actions/workflows/ci.yml)

Start a program from Goose. Read what it prints and the code it ends with.
Feed it input. Set its environment and its directory. Stop it on a timeout.

The package is a stopgap. Drop it when the standard library has the same
functions.

## Install

Add this to the root file of the program that uses it:

```goose
import process from "rekanalar/goose-process@v0.1.1";
```

The CI runs the gate on Linux, on macOS and on Windows. It uses Goose
v2026.3 and v2026.4 on each.

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
import process from "rekanalar/goose-process@v0.1.1";

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

## API

| Function | Purpose |
|---|---|
| `process::options()` | Return an `Options` with the defaults. |
| `process::run(cmd, args, input, opts)` | Start the program `cmd` with the arguments `args`. Write `input` to its standard input. Wait for it. Return a `Result`. |

`cmd` is the name of the program. It is the first argument of the child.
`args` holds the other arguments. `input` holds the bytes for the standard
input of the child. `opts` holds the settings.

### The statuses

| Constant | Value | Meaning |
|---|---|---|
| `process::ENDED` | 0 | The child ran and ended. The code holds its exit code. |
| `process::NOT_STARTED` | 1 | The child did not start. The program does not exist, or the directory is bad. |
| `process::STOPPED` | 2 | The child was stopped on the time limit. |
| `process::REFUSED` | 3 | The package refused the request. It started no program. |

### Options

| Field | Type | Meaning |
|---|---|---|
| `cwd` | `u8[..255]` | The working directory of the child. Empty means the directory of the parent. |
| `timeout_ms` | `i32` | The time limit in milliseconds. 0 means no limit. |
| `env` | `const u8[:][>..]` | The entries to set or to change. Each entry is `NAME=VALUE`. Empty means the environment of the parent. |

A variable that the caller does not set keeps the value of the parent.

### Result

| Field | Type | Meaning |
|---|---|---|
| `status` | `i32` | One of the four statuses. |
| `code` | `i32` | The exit code of the child. It has no meaning when the child was stopped. |
| `output` | `u8[>..]` | The standard output and the standard error of the child, joined. |

## The C part

The package wraps one C header. The header is `subprocess.h` of sheredom,
under the Unlicense. It sits under `vendor/`. The Goose compiler ships the
same header in `third_party/subprocess/`.

The C layer of this package sits in `src/proc.c`. It takes one flat byte
buffer. The buffer holds the arguments, the environment and the directory.
The C function has five argument slots, so it stays safe on the TinyCC JIT
of macOS and arm64.

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

## Not verified

- The quoting of arguments on Windows beyond the tests of this package.
- A child that ignores the stop signal. The test runs on Unix only.
- The grandchildren of a child.
- The cancel of a blocked write on Windows. No machine of this project
  runs Windows. The CI runs the suite there on every push.

## Test

```sh
TMPDIR=/some/scratch bash run-gate.sh /path/to/goose-release
```

The gate checks the entry file, then runs and builds the tests and each
example. Run it once for each compiler.

## License

MIT
