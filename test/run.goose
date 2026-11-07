// The acceptance tests of the process package.
//
// The test picks the programs that the system holds. Windows holds cmd, not
// the programs of Unix. Some checks run on Unix only.

import std;
import os;
import process from "..";

// A program that the test starts.
struct Program {
    name: const u8[:],
    args: const u8[:][>..],
}

// The test runs on Windows and on Unix.
fn is_windows() -> bool {
    var value: u8[>..] = [];
    if !env("OS", value) {
        return false;
    }
    return value == "Windows_NT";
}

// A program that prints its text.
fn echo_program(text: const u8[:]) -> Program {
    var args: const u8[:][>..] = [];
    if is_windows() {
        args.push("/c");
        args.push("echo");
        args.push(text);
        return Program { name: "cmd", args: copy(args) };
    }
    args.push(text);
    return Program { name: "echo", args: copy(args) };
}

// A program that ends with a code.
fn exit_program() -> Program {
    var args: const u8[:][>..] = [];
    if is_windows() {
        args.push("/c");
        args.push("exit 3");
        return Program { name: "cmd", args: copy(args) };
    }
    args.push("-c");
    args.push("exit 3");
    return Program { name: "sh", args: copy(args) };
}

// A program that writes to its error output.
fn error_program() -> Program {
    var args: const u8[:][>..] = [];
    if is_windows() {
        args.push("/c");
        args.push("echo to-err 1>&2");
        return Program { name: "cmd", args: copy(args) };
    }
    args.push("-c");
    args.push("echo to-err 1>&2");
    return Program { name: "sh", args: copy(args) };
}

// A program that never ends.
fn hang_program() -> Program {
    var args: const u8[:][>..] = [];
    if is_windows() {
        args.push("/c");
        args.push("ping -n 31 127.0.0.1 > nul");
        return Program { name: "cmd", args: copy(args) };
    }
    args.push("30");
    return Program { name: "sleep", args: copy(args) };
}

// A program that ignores the stop signal.
fn stubborn_program() -> Program {
    var args: const u8[:][>..] = [];
    args.push("-c");
    args.push("trap '' TERM; sleep 30");
    return Program { name: "sh", args: copy(args) };
}

// A program that reads its input and prints it.
fn cat_program() -> Program {
    var args: const u8[:][>..] = [];
    if is_windows() {
        args.push("/c");
        args.push("more");
        return Program { name: "cmd", args: copy(args) };
    }
    return Program { name: "cat", args: copy(args) };
}

// A program that prints a file.
fn file_program(path: const u8[:]) -> Program {
    var args: const u8[:][>..] = [];
    if is_windows() {
        args.push("/c");
        args.push("type");
        args.push(path);
        return Program { name: "cmd", args: copy(args) };
    }
    args.push(path);
    return Program { name: "cat", args: copy(args) };
}

// A program that prints the value of a variable.
fn var_program() -> Program {
    var args: const u8[:][>..] = [];
    if is_windows() {
        args.push("/c");
        args.push("echo %GOOSE_PROCESS_TEST%");
        return Program { name: "cmd", args: copy(args) };
    }
    args.push("-c");
    args.push("echo $GOOSE_PROCESS_TEST");
    return Program { name: "sh", args: copy(args) };
}

// A program that prints the value of a variable of the parent.
fn path_program() -> Program {
    var args: const u8[:][>..] = [];
    if is_windows() {
        args.push("/c");
        args.push("echo %PATH%");
        return Program { name: "cmd", args: copy(args) };
    }
    args.push("-c");
    args.push("echo $PATH");
    return Program { name: "sh", args: copy(args) };
}

// A program that prints its directory.
fn pwd_program() -> Program {
    var args: const u8[:][>..] = [];
    if is_windows() {
        args.push("/c");
        args.push("cd");
        return Program { name: "cmd", args: copy(args) };
    }
    args.push("-c");
    args.push("pwd");
    return Program { name: "sh", args: copy(args) };
}

// The output without its last line ending and trailing spaces. cmd keeps
// the space before a redirect in the text that it echoes.
fn cut_end(text: const u8[:]) -> const u8[:] {
    var end = text.len;
    while end > 0 {
        let last = text[end - 1];
        if last != 10 && last != 13 && last != 32 {
            break;
        }
        end--;
    }
    return text[..end];
}

// The scratch directory of the test.
fn scratch(out: u8[>..]&) {
    if !env("TMPDIR", out) {
        out.append(".");
    }
}

// The test of the first run.
fn test_run() {
    let p = echo_program("hi");
    var opts = process::options();
    let r = process::run(p.name, p.args, "", opts);
    assert(r.status == process::ENDED);
    assert(r.code == 0);
    assert(cut_end(r.output) == "hi");
}

// The test of the exit code.
fn test_exit_code() {
    let p = exit_program();
    var opts = process::options();
    let r = process::run(p.name, p.args, "", opts);
    assert(r.status == process::ENDED);
    assert(r.code == 3);
}

// The test of the error output.
fn test_error_output() {
    let p = error_program();
    var opts = process::options();
    let r = process::run(p.name, p.args, "", opts);
    assert(r.status == process::ENDED);
    assert(cut_end(r.output) == "to-err");
}

// The test of a program that does not exist.
fn test_missing_program() {
    var opts = process::options();
    var none: const u8[:][>..] = [];
    let start = clock_ns();
    let r = process::run("goose-no-such-program", none, "", opts);
    let ms = (clock_ns() - start) / 1000000;
    assert(r.status == process::NOT_STARTED);
    assert(ms < 1000);
}

// The test of the time limit.
fn test_timeout() {
    let p = hang_program();
    var opts = process::options();
    opts.timeout_ms = 300;
    let start = clock_ns();
    let r = process::run(p.name, p.args, "", opts);
    let ms = (clock_ns() - start) / 1000000;
    assert(r.status == process::STOPPED);
    assert(ms >= 250);
    assert(ms < 5000);
}

// The test of a child that ends on its own.
fn test_no_limit() {
    let p = exit_program();
    var opts = process::options();
    let r = process::run(p.name, p.args, "", opts);
    assert(r.status == process::ENDED);
    assert(r.code == 3);
}

// The test of a child that ignores the stop signal.
fn test_stubborn_child() {
    if is_windows() {
        return;
    }
    let p = stubborn_program();
    var opts = process::options();
    opts.timeout_ms = 300;
    let start = clock_ns();
    let r = process::run(p.name, p.args, "", opts);
    let ms = (clock_ns() - start) / 1000000;
    assert(r.status == process::STOPPED);
    assert(ms >= 250);
    assert(ms < 5000);
}

// The test of the input of the child.
fn test_input() {
    let p = cat_program();
    var opts = process::options();
    let r = process::run(p.name, p.args, "fed through stdin", opts);
    assert(r.status == process::ENDED);
    assert(cut_end(r.output) == "fed through stdin");
}

// The test of a large input.
fn test_large_input() {
    if is_windows() {
        return;
    }
    var data: u8[>..] = [];
    var chunk: u8[>..] = [];
    for i in 0..65536 {
        chunk.push(120);
    }
    for i in 0..16 {
        data.append(chunk);
    }
    let p = cat_program();
    var opts = process::options();
    opts.timeout_ms = 30000;
    let r = process::run(p.name, p.args, data, opts);
    assert(r.status == process::ENDED);
    assert(r.output.len == data.len);
    assert(r.output[0] == 120);
    assert(r.output[r.output.len - 1] == 120);
}

// The test of a large output.
fn test_large_output() {
    var chunk: u8[>..] = [];
    for i in 0..65536 {
        chunk.push(120);
    }
    var dir: u8[>..] = [];
    scratch(dir);
    var path: u8[>..] = [];
    path.append(dir);
    path.append("/goose-process-big.txt");
    assert(write_file(path, chunk));
    for i in 0..15 {
        append_file(path, chunk);
    }
    let p = file_program(path);
    var opts = process::options();
    opts.timeout_ms = 30000;
    let r = process::run(p.name, p.args, "", opts);
    assert(r.status == process::ENDED);
    assert(r.output.len == 16 * 65536);
    assert(r.output[r.output.len - 1] == 120);
    delete_file(path);
}

// The test of the environment of the child.
fn test_environment() {
    var opts = process::options();
    opts.env.push("GOOSE_PROCESS_TEST=hello");
    let p = var_program();
    let r = process::run(p.name, p.args, "", opts);
    assert(r.status == process::ENDED);
    assert(cut_end(r.output) == "hello");

    // A variable that the caller does not set keeps the value of the parent.
    var parent: u8[>..] = [];
    assert(env("PATH", parent));
    let q = path_program();
    var plain = process::options();
    let s = process::run(q.name, q.args, "", plain);
    assert(s.status == process::ENDED);
    assert(cut_end(s.output) == cut_end(parent));
}

// The test of a variable that the parent holds.
fn test_override() {
    var parent: u8[>..] = [];
    assert(env("PATH", parent));
    var opts = process::options();
    opts.env.push("PATH=goose-process-path");
    let q = path_program();
    let s = process::run(q.name, q.args, "", opts);
    assert(s.status == process::ENDED);
    assert(cut_end(s.output) == "goose-process-path");
}

// The test of the directory of the child.
fn test_directory() {
    var dir: u8[>..] = [];
    scratch(dir);
    var opts = process::options();
    opts.cwd = dir;
    let p = pwd_program();
    let r = process::run(p.name, p.args, "", opts);
    assert(r.status == process::ENDED);
    assert(cut_end(r.output) == cut_end(dir));

    // A directory that does not exist stops the child.
    var bad = process::options();
    bad.cwd = "no-such-directory-xyz";
    let q = pwd_program();
    let s = process::run(q.name, q.args, "", bad);
    assert(s.status == process::NOT_STARTED);
}

// The test of a request that the package refuses.
fn test_refused() {
    var opts = process::options();
    var many: const u8[:][>..] = [];
    for i in 0..70 {
        many.push("x");
    }
    let r = process::run("echo", many, "", opts);
    assert(r.status == process::REFUSED);

    var bad = process::options();
    bad.env.push("NO_EQUALS_SIGN");
    let p = echo_program("hi");
    let s = process::run(p.name, p.args, "", bad);
    assert(s.status == process::REFUSED);
}

// The test of a NUL byte in an argument.
fn test_nul_cut() {
    if is_windows() {
        return;
    }
    var args: const u8[:][>..] = [];
    args.push("-c");
    args.push("printf %s \"$1\"");
    args.push("sh");
    args.push("a\0b");
    var opts = process::options();
    let r = process::run("sh", args, "", opts);
    assert(r.status == process::ENDED);
    assert(r.output == "a");
}

// The test that the package starts no shell.
fn test_no_shell() {
    if is_windows() {
        return;
    }
    var args: const u8[:][>..] = [];
    args.push("-c");
    args.push("printf %s \"$1\"");
    args.push("sh");
    args.push("a b;c");
    var opts = process::options();
    let r = process::run("sh", args, "", opts);
    assert(r.status == process::ENDED);
    assert(r.output == "a b;c");
}

fn main() {
    test_run();
    test_exit_code();
    test_error_output();
    test_missing_program();
    test_timeout();
    test_no_limit();
    test_stubborn_child();
    test_input();
    test_large_input();
    test_large_output();
    test_environment();
    test_override();
    test_directory();
    test_refused();
    test_nul_cut();
    test_no_shell();
    print("process tests passed");
    return 0;
}
