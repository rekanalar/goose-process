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
// The status of a child that lives.
const RUNNING = 4;

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
    // The output stream and the error stream stay apart.
    separate: bool = false,
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

// The C layer of the live child. Each call carries the number of the slot
// of the child.
extern fn proc_spawn(spec: const u8[:], separate: i32, status: i32&) -> i32;
extern fn proc_alive(id: i32) -> i32;
extern fn proc_read(id: i32, out: u8[>..]&, err: u8[>..]&) -> i32;
extern fn proc_write(id: i32, bytes: const u8[:], timeout_ms: i32) -> i32;
extern fn proc_close_in(id: i32) -> i32;
extern fn proc_wait(id: i32, code: i32&, timeout_ms: i32) -> i32;
extern fn proc_kill(id: i32) -> i32;
extern fn proc_free(id: i32) -> i32;

// A child that lives. The caller starts it with spawn.
struct Child {
    // The number of the slot of the child. It is below zero when the child
    // did not start.
    id: i32 = -1,
    // One of RUNNING, NOT_STARTED, STOPPED and REFUSED.
    status: i32 = 0,
}

// The result of a wait for a child.
struct Outcome {
    // One of ENDED, STOPPED and NOT_STARTED.
    status: i32 = 0,
    // The exit code of the child. It has no meaning when the child was
    // stopped.
    code: i32 = 0,
}

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
    // The child sees the entry up to its first NUL byte.
    for i in cut_at_nul(entry) {
        if entry[i] == 61 {
            return true;
        }
    }
    return false;
}

// A request that the package refuses. Both starts share the checks.
fn refused_request(cmd: const u8[:], args: const u8[:][>..]&, opts: Options&) -> bool {
    if cmd.len == 0 || args.len + 1 > MAX_ARGS {
        return true;
    }
    for entry in opts.env {
        if !has_equals(entry) {
            return true;
        }
    }
    return false;
}

// The flat buffer of a start. It holds the arguments, the environment and
// the directory.
fn pack_spec(cmd: const u8[:], args: const u8[:][>..]&, opts: Options&, out: u8[>..]&) {
    pack_count(out, args.len + 1);
    pack_item(out, cmd);
    for a in args {
        pack_item(out, a);
    }
    pack_count(out, opts.env.len);
    for entry in opts.env {
        pack_item(out, entry);
    }
    pack_item(out, opts.cwd);
}

// run starts the program cmd with the arguments args. It writes the bytes
// of input to the standard input of the child. It waits for the child.
//
// The result holds the status, the exit code and the output. The status
// says that the child ended, that it did not start, that it was stopped on
// the limit, or that the request was refused. run holds one joined buffer,
// so it refuses a request that sets separate.
fn run(cmd: const u8[:], args: const u8[:][>..]&, input: const u8[:], opts: Options&) -> Result {
    var result = Result { };
    if opts.separate || refused_request(cmd, args, opts) {
        result.status = REFUSED;
        return result;
    }

    var spec: u8[>..] = [];
    pack_spec(cmd, args, opts, spec);

    var code: i32 = 0;
    let status = proc_run(spec, input, result.output, code, opts.timeout_ms);
    result.status = status;
    result.code = code;
    return result;
}

// spawn starts the program cmd with the arguments args. It returns without
// waiting for the child. The child holds RUNNING when it lives, NOT_STARTED
// when the program does not exist, and REFUSED when the request was
// refused.
fn spawn(cmd: const u8[:], args: const u8[:][>..]&, opts: Options&) -> Child {
    var child = Child { };
    if refused_request(cmd, args, opts) {
        child.status = REFUSED;
        return child;
    }

    var spec: u8[>..] = [];
    pack_spec(cmd, args, opts, spec);

    var separate: i32 = 0;
    if opts.separate {
        separate = 1;
    }
    var status: i32 = 0;
    let id = proc_spawn(spec, separate, status);
    if id < 0 {
        child.status = status;
        return child;
    }
    child.id = id;
    child.status = RUNNING;
    return child;
}

// alive says whether the child still lives.
fn alive(child: Child) -> bool {
    return proc_alive(child.id) == 1;
}

// read moves the bytes that arrived since the last read into the buffer out
// and the buffer err. It returns the count of the moved bytes. The read
// returns at once when no bytes wait. The buffer err stays empty when the
// child holds the two streams joined.
fn read(child: Child, out: u8[>..]&, err: u8[>..]&) -> i32 {
    return proc_read(child.id, out, err);
}

// write gives the bytes to the input of the child. It waits while the
// child does not take them. It returns the count of the taken bytes. It
// returns a number below zero when the child is gone.
fn write(child: Child, bytes: const u8[:]) -> i32 {
    return proc_write(child.id, bytes, 0);
}

// close_input closes the input of the child. The child then sees the end
// of its input.
fn close_input(child: Child) -> i32 {
    return proc_close_in(child.id);
}

// wait waits for the child. A limit of 0 waits without a limit. A child
// that does not end before the limit is stopped. The outcome holds the
// status and the exit code of the child.
fn wait(child: Child, timeout_ms: i32) -> Outcome {
    var outcome = Outcome { };
    if child.id < 0 {
        outcome.status = child.status;
        return outcome;
    }
    var code: i32 = 0;
    outcome.status = proc_wait(child.id, code, timeout_ms);
    outcome.code = code;
    return outcome;
}

// kill stops the child. The stop stays a kill. It returns the status of
// the child after the stop.
fn kill(child: Child) -> i32 {
    if child.id < 0 {
        return child.status;
    }
    return proc_kill(child.id);
}

// free stops the child when it still lives, then it frees the handle. It
// returns the status of the child after the stop.
fn free(child: Child) -> i32 {
    if child.id < 0 {
        return child.status;
    }
    return proc_free(child.id);
}

// run_split starts the program cmd with the arguments args and waits for
// it. It writes the bytes of input to the standard input of the child. It
// keeps the output stream and the error stream apart. It writes the output
// stream into the buffer out and the error stream into the buffer err. The
// outcome holds the status and the exit code of the child.
fn run_split(cmd: const u8[:], args: const u8[:][>..]&, input: const u8[:],
             opts: Options&, out: u8[>..]&, err: u8[>..]&) -> Outcome {
    // A copy of a struct shares the buffer of a growable field. The new
    // options take their own entries.
    var split_opts = options();
    split_opts.cwd = opts.cwd;
    split_opts.timeout_ms = opts.timeout_ms;
    split_opts.separate = true;
    for entry in opts.env {
        split_opts.env.push(entry);
    }
    let child = spawn(cmd, args, split_opts);
    var outcome = Outcome { };
    if child.status != RUNNING {
        outcome.status = child.status;
        return outcome;
    }
    if input.len > 0 {
        // The write keeps the limit. A child that never reads its input is
        // stopped, so the run cannot hang.
        let taken = proc_write(child.id, input, opts.timeout_ms);
        if taken >= 0 && taken < input.len {
            kill(child);
        }
    }
    close_input(child);
    outcome = wait(child, opts.timeout_ms);
    read(child, out, err);
    free(child);
    return outcome;
}
