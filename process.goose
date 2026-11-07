// process: start programs, read their output and stop them on a timeout.
//
// This package is a stopgap. Drop it when the standard library has the same
// functions.
namespace process;

import std;

// The status of a run.
const ENDED = 0;
const NOT_STARTED = 1;
const STOPPED = 2;
const REFUSED = 3;

// The child gets at most this many arguments. The name of the program is
// one of them.
const MAX_ARGS = 64;

// The settings of one run.
struct Options {
    // The working directory of the child. Empty means the directory of the
    // parent.
    cwd: u8[..255] = [],
    // The time limit in milliseconds. 0 means no limit.
    timeout_ms: i32 = 0,
    // The entries to set or to change. Each entry is NAME=VALUE.
    env: const u8[:][>..] = [],
}

// The result of one run.
struct Result {
    // One of ENDED, NOT_STARTED, STOPPED and REFUSED.
    status: i32 = 0,
    // The exit code of the child. It has no meaning when the child was
    // stopped.
    code: i32 = 0,
    // The standard output and the standard error of the child, joined.
    output: u8[>..] = [],
}

// The C layer. It starts the child and it fills the buffer, the code and
// the status.
extern fn proc_run(spec: const u8[:], input: const u8[:], out: u8[>..]&, code: i32&, timeout_ms: i32) -> i32;

// options returns the default settings.
fn options() -> Options {
    return Options { };
}

// A count goes into the flat buffer as a number and a newline.
fn pack_count(out: u8[>..]&, count: i64) {
    format_int(out, count, 10, 0, ' ');
    out.push(10);
}

// The length of an item up to its first NUL byte. The operating system
// cannot pass a NUL byte inside an argument.
fn cut_at_nul(item: const u8[:]) -> i64 {
    for i in item.len {
        if item[i] == 0 {
            return i;
        }
    }
    return item.len;
}

// An item goes into the flat buffer as bytes and a NUL. The bytes end at
// the first NUL of the item.
fn pack_item(out: u8[>..]&, item: const u8[:]) {
    out.append(item[..cut_at_nul(item)]);
    out.push(0);
}

// An environment entry needs an equals sign.
fn has_equals(entry: const u8[:]) -> bool {
    for i in entry.len {
        if entry[i] == 61 {
            return true;
        }
    }
    return false;
}

// run starts the program cmd with the arguments args. It writes the bytes
// of input to the standard input of the child. It waits for the child.
//
// The result holds the status, the exit code and the output. The status
// says that the child ended, that it did not start, that it was stopped on
// the limit, or that the request was refused.
fn run(cmd: const u8[:], args: const u8[:][>..]&, input: const u8[:], opts: Options&) -> Result {
    var result = Result { };
    if cmd.len == 0 || args.len + 1 > MAX_ARGS {
        result.status = REFUSED;
        return result;
    }
    for entry in opts.env {
        if !has_equals(entry) {
            result.status = REFUSED;
            return result;
        }
    }

    var spec: u8[>..] = [];
    pack_count(spec, args.len + 1);
    pack_item(spec, cmd);
    for a in args {
        pack_item(spec, a);
    }
    pack_count(spec, opts.env.len);
    for entry in opts.env {
        pack_item(spec, entry);
    }
    pack_item(spec, opts.cwd);

    var code: i32 = 0;
    let status = proc_run(spec, input, result.output, code, opts.timeout_ms);
    result.status = status;
    result.code = code;
    return result;
}
