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

// The path with the separators of Windows, written into out. cmd reads a
// slash in an argument as the start of a switch.
fn dos_path(out: u8[>..]&, text: const u8[:]) {
    for i in text.len {
        if text[i] == 47 {
            out.push(92);
        } else {
            out.push(text[i]);
        }
    }
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

// A program that writes to both outputs.
fn split_program() -> Program {
    var args: const u8[:][>..] = [];
    if is_windows() {
        args.push("/c");
        args.push("echo out& echo err 1>&2");
        return Program { name: "cmd", args: copy(args) };
    }
    args.push("-c");
    args.push("echo out; echo err 1>&2");
    return Program { name: "sh", args: copy(args) };
}

// A program that prints two lines with a pause between them.
fn slow_printer() -> Program {
    var args: const u8[:][>..] = [];
    if is_windows() {
        args.push("/c");
        args.push("echo one& ping -n 2 127.0.0.1 > nul& echo two");
        return Program { name: "cmd", args: copy(args) };
    }
    args.push("-c");
    args.push("echo one; sleep 1; echo two");
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
    var wpath: u8[>..] = [];
    if is_windows() {
        dos_path(wpath, path);
    } else {
        wpath.append(path);
    }
    let p = file_program(wpath);
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

// The test of a child that lives.
fn test_live_child() {
    let p = hang_program();
    var opts = process::options();
    let child = process::spawn(p.name, p.args, opts);
    assert(child.status == process::RUNNING);
    assert(process::alive(child));
    assert(process::alive(child));
    assert(process::kill(child) == process::STOPPED);
    let outcome = process::wait(child, 1000);
    assert(outcome.status == process::STOPPED);
    assert(!process::alive(child));
    assert(process::free(child) == process::STOPPED);
}

// The test of a wait without a limit.
fn test_wait_ended() {
    let p = exit_program();
    var opts = process::options();
    let child = process::spawn(p.name, p.args, opts);
    let outcome = process::wait(child, 0);
    assert(outcome.status == process::ENDED);
    assert(outcome.code == 3);
    assert(process::free(child) == process::ENDED);
}

// The test of a wait with a limit.
fn test_wait_limit() {
    let p = hang_program();
    var opts = process::options();
    let child = process::spawn(p.name, p.args, opts);
    let start = clock_ns();
    let outcome = process::wait(child, 300);
    let ms = (clock_ns() - start) / 1000000;
    assert(outcome.status == process::STOPPED);
    assert(ms >= 250);
    assert(ms < 5000);
    process::free(child);
}

// The test of a start of a program that does not exist.
fn test_spawn_missing() {
    var opts = process::options();
    var none: const u8[:][>..] = [];
    let start = clock_ns();
    let child = process::spawn("goose-no-such-program", none, opts);
    let ms = (clock_ns() - start) / 1000000;
    assert(child.status == process::NOT_STARTED);
    assert(child.id < 0);
    assert(ms < 1000);
}

// The test of a child that is killed twice.
fn test_kill_twice() {
    let p = hang_program();
    var opts = process::options();
    let child = process::spawn(p.name, p.args, opts);
    assert(process::kill(child) == process::STOPPED);
    assert(process::kill(child) == process::STOPPED);
    process::free(child);
}

// The test of a free of a live child.
fn test_free_live() {
    let p = hang_program();
    var opts = process::options();
    let child = process::spawn(p.name, p.args, opts);
    assert(process::free(child) == process::STOPPED);
    assert(!process::alive(child));
}

// The test of eight children at the same time.
fn test_eight_children() {
    let p = hang_program();
    var opts = process::options();
    let c1 = process::spawn(p.name, p.args, opts);
    let c2 = process::spawn(p.name, p.args, opts);
    let c3 = process::spawn(p.name, p.args, opts);
    let c4 = process::spawn(p.name, p.args, opts);
    let c5 = process::spawn(p.name, p.args, opts);
    let c6 = process::spawn(p.name, p.args, opts);
    let c7 = process::spawn(p.name, p.args, opts);
    let c8 = process::spawn(p.name, p.args, opts);
    assert(process::alive(c1) && process::alive(c2));
    assert(process::alive(c3) && process::alive(c4));
    assert(process::alive(c5) && process::alive(c6));
    assert(process::alive(c7) && process::alive(c8));
    assert(process::free(c1) == process::STOPPED);
    assert(process::free(c2) == process::STOPPED);
    assert(process::free(c3) == process::STOPPED);
    assert(process::free(c4) == process::STOPPED);
    assert(process::free(c5) == process::STOPPED);
    assert(process::free(c6) == process::STOPPED);
    assert(process::free(c7) == process::STOPPED);
    assert(process::free(c8) == process::STOPPED);
}

// The test of a full table. The start that finds no slot is refused, and a
// free makes room again.
fn test_table_full() {
    let p = hang_program();
    var opts = process::options();
    var c1 = process::spawn(p.name, p.args, opts);
    var c2 = process::spawn(p.name, p.args, opts);
    var c3 = process::spawn(p.name, p.args, opts);
    var c4 = process::spawn(p.name, p.args, opts);
    var c5 = process::spawn(p.name, p.args, opts);
    var c6 = process::spawn(p.name, p.args, opts);
    var c7 = process::spawn(p.name, p.args, opts);
    var c8 = process::spawn(p.name, p.args, opts);
    var c9 = process::spawn(p.name, p.args, opts);
    var c10 = process::spawn(p.name, p.args, opts);
    var c11 = process::spawn(p.name, p.args, opts);
    var c12 = process::spawn(p.name, p.args, opts);
    var c13 = process::spawn(p.name, p.args, opts);
    var c14 = process::spawn(p.name, p.args, opts);
    var c15 = process::spawn(p.name, p.args, opts);
    var c16 = process::spawn(p.name, p.args, opts);
    assert(c1.status == process::RUNNING);
    assert(c16.status == process::RUNNING);
    var extra = process::spawn(p.name, p.args, opts);
    assert(extra.status == process::REFUSED);
    assert(process::free(c1) == process::STOPPED);
    var again = process::spawn(p.name, p.args, opts);
    assert(again.status == process::RUNNING);
    assert(process::free(again) == process::STOPPED);
    assert(process::free(c2) == process::STOPPED);
    assert(process::free(c3) == process::STOPPED);
    assert(process::free(c4) == process::STOPPED);
    assert(process::free(c5) == process::STOPPED);
    assert(process::free(c6) == process::STOPPED);
    assert(process::free(c7) == process::STOPPED);
    assert(process::free(c8) == process::STOPPED);
    assert(process::free(c9) == process::STOPPED);
    assert(process::free(c10) == process::STOPPED);
    assert(process::free(c11) == process::STOPPED);
    assert(process::free(c12) == process::STOPPED);
    assert(process::free(c13) == process::STOPPED);
    assert(process::free(c14) == process::STOPPED);
    assert(process::free(c15) == process::STOPPED);
    assert(process::free(c16) == process::STOPPED);
}

// The test of the bytes that arrive while the child runs.
fn test_stream_first_line() {
    let p = slow_printer();
    var opts = process::options();
    let child = process::spawn(p.name, p.args, opts);
    var text: u8[>..] = [];
    var errors: u8[>..] = [];
    while text == "" {
        process::read(child, text, errors);
    }
    assert(cut_end(text) == "one");
    let outcome = process::wait(child, 0);
    assert(outcome.status == process::ENDED);
    process::read(child, text, errors);
    if is_windows() {
        assert(cut_end(text) == "one\r\ntwo");
    } else {
        assert(cut_end(text) == "one\ntwo");
    }
    process::free(child);
}

// The test of a read on a child that prints nothing.
fn test_read_silent() {
    let p = exit_program();
    var opts = process::options();
    let child = process::spawn(p.name, p.args, opts);
    var text: u8[>..] = [];
    var errors: u8[>..] = [];
    assert(process::read(child, text, errors) == 0);
    let outcome = process::wait(child, 0);
    assert(outcome.status == process::ENDED);
    assert(process::read(child, text, errors) == 0);
    process::free(child);
}

// The test of the reads together holding the whole output.
fn test_read_to_end() {
    let p = echo_program("wholeoutput");
    var opts = process::options();
    let child = process::spawn(p.name, p.args, opts);
    var text: u8[>..] = [];
    var errors: u8[>..] = [];
    while process::alive(child) {
        process::read(child, text, errors);
    }
    let outcome = process::wait(child, 0);
    assert(outcome.status == process::ENDED);
    process::read(child, text, errors);
    assert(cut_end(text) == "wholeoutput");
    process::free(child);
}

// The test of the bytes that remain after the child ended.
fn test_read_after_end() {
    let p = echo_program("tail");
    var opts = process::options();
    let child = process::spawn(p.name, p.args, opts);
    let outcome = process::wait(child, 0);
    assert(outcome.status == process::ENDED);
    var text: u8[>..] = [];
    var errors: u8[>..] = [];
    let count = process::read(child, text, errors);
    assert(count > 0);
    assert(cut_end(text) == "tail");
    assert(process::read(child, text, errors) == 0);
    process::free(child);
}

// The test of a large output on a live child. The caller keeps reading, so
// the child never waits on a full pipe.
fn test_large_live_output() {
    if is_windows() {
        return;
    }
    var args: const u8[:][>..] = [];
    args.push("-c");
    args.push("i=0; while [ $i -lt 20000 ]; do echo line; i=$((i+1)); done");
    var opts = process::options();
    let child = process::spawn("sh", args, opts);
    var text: u8[>..] = [];
    var errors: u8[>..] = [];
    while process::alive(child) {
        process::read(child, text, errors);
    }
    let outcome = process::wait(child, 30000);
    assert(outcome.status == process::ENDED);
    process::read(child, text, errors);
    assert(text.len == 20000 * 5);
    process::free(child);
}

// The test of the apart run of one shot.
fn test_split_run() {
    let p = split_program();
    var opts = process::options();
    var out: u8[>..] = [];
    var err: u8[>..] = [];
    let outcome = process::run_split(p.name, p.args, "", opts, out, err);
    assert(outcome.status == process::ENDED);
    assert(outcome.code == 0);
    assert(cut_end(out) == "out");
    assert(cut_end(err) == "err");
}

// The test of the apart streams on a handle.
fn test_split_handle() {
    let p = split_program();
    var opts = process::options();
    opts.separate = true;
    let child = process::spawn(p.name, p.args, opts);
    assert(child.status == process::RUNNING);
    let outcome = process::wait(child, 0);
    assert(outcome.status == process::ENDED);
    var out: u8[>..] = [];
    var err: u8[>..] = [];
    process::read(child, out, err);
    assert(cut_end(out) == "out");
    assert(cut_end(err) == "err");
    process::free(child);
}

// The test that the joined run of v0.1.x stays.
fn test_joined_unchanged() {
    let p = error_program();
    var opts = process::options();
    let r = process::run(p.name, p.args, "", opts);
    assert(r.status == process::ENDED);
    assert(cut_end(r.output) == "to-err");
}

// The test that run refuses the apart option.
fn test_run_refuses_separate() {
    let p = echo_program("hi");
    var opts = process::options();
    opts.separate = true;
    let r = process::run(p.name, p.args, "", opts);
    assert(r.status == process::REFUSED);
}

// The test of two chained children. The result matches the direct run.
fn test_chain() {
    let first = echo_program("hello-chain");
    var opts = process::options();
    let a = process::spawn(first.name, first.args, opts);
    var text: u8[>..] = [];
    var errors: u8[>..] = [];
    while process::alive(a) {
        process::read(a, text, errors);
    }
    let one = process::wait(a, 0);
    assert(one.status == process::ENDED);
    process::read(a, text, errors);
    process::free(a);

    let second = cat_program();
    let b = process::spawn(second.name, second.args, opts);
    assert(process::write(b, text) > 0);
    assert(process::close_input(b) == 0);
    var answer: u8[>..] = [];
    while process::alive(b) {
        process::read(b, answer, errors);
    }
    let two = process::wait(b, 0);
    assert(two.status == process::ENDED);
    process::read(b, answer, errors);
    process::free(b);
    assert(cut_end(answer) == "hello-chain");

    let direct = process::run(second.name, second.args, text, opts);
    assert(direct.status == process::ENDED);
    assert(cut_end(direct.output) == "hello-chain");
}

// The test of a chain where the first child fails. The caller sees the code
// and stops before the second child starts.
fn test_chain_fail() {
    let first = exit_program();
    var opts = process::options();
    let a = process::spawn(first.name, first.args, opts);
    let one = process::wait(a, 0);
    assert(one.status == process::ENDED);
    assert(one.code == 3);
    process::free(a);
}

// The test of a write to a child that is gone. It reports the death and it
// does not hang.
fn test_write_dead() {
    let p = exit_program();
    var opts = process::options();
    let child = process::spawn(p.name, p.args, opts);
    let outcome = process::wait(child, 0);
    assert(outcome.status == process::ENDED);
    let start = clock_ns();
    let wrote = process::write(child, "too late");
    let ms = (clock_ns() - start) / 1000000;
    assert(wrote < 0);
    assert(ms < 1000);
    process::free(child);
}

// The test of the end of the input. The child ends after the close.
fn test_close_input_eof() {
    let p = cat_program();
    var opts = process::options();
    let child = process::spawn(p.name, p.args, opts);
    assert(process::close_input(child) == 0);
    let outcome = process::wait(child, 5000);
    assert(outcome.status == process::ENDED);
    assert(outcome.code == 0);
    process::free(child);
}

// The test that run_split keeps its limit while it writes. The child never
// reads its input.
fn test_split_write_limit() {
    if is_windows() {
        return;
    }
    var data: u8[>..] = [];
    var chunk: u8[>..] = [];
    for i in 0..65536 {
        chunk.push(120);
    }
    for i in 0..4 {
        data.append(chunk);
    }
    let p = hang_program();
    var opts = process::options();
    opts.timeout_ms = 500;
    var out: u8[>..] = [];
    var err: u8[>..] = [];
    let start = clock_ns();
    let outcome = process::run_split(p.name, p.args, data, opts, out, err);
    let ms = (clock_ns() - start) / 1000000;
    assert(outcome.status == process::STOPPED);
    assert(ms < 5000);
}

// The test of an environment entry whose equals sign sits after a NUL byte.
fn test_env_nul_refused() {
    var bad = process::options();
    bad.env.push("FOO\0=bar");
    let p = echo_program("hi");
    let r = process::run(p.name, p.args, "", bad);
    assert(r.status == process::REFUSED);
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
    test_live_child();
    test_wait_ended();
    test_wait_limit();
    test_spawn_missing();
    test_kill_twice();
    test_free_live();
    test_eight_children();
    test_table_full();
    test_stream_first_line();
    test_read_silent();
    test_read_to_end();
    test_read_after_end();
    test_large_live_output();
    test_split_run();
    test_split_handle();
    test_joined_unchanged();
    test_run_refuses_separate();
    test_chain();
    test_chain_fail();
    test_write_dead();
    test_close_input_eof();
    test_split_write_limit();
    test_env_nul_refused();
    print("process tests passed");
    return 0;
}
