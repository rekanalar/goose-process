// The example of a live child. It starts a program, reads its output while
// it runs, waits for it and frees the handle.

import std;
import os;
import process from "..";

// The example runs on Windows and on Unix.
fn is_windows() -> bool {
    var value: u8[>..] = [];
    if !env("OS", value) {
        return false;
    }
    return value == "Windows_NT";
}

fn main() {
    var args: const u8[:][>..] = [];
    var name = "echo";
    if is_windows() {
        name = "cmd";
        args.push("/c");
        args.push("echo");
    }
    args.push("live child");

    var opts = process::options();
    let child = process::spawn(name, args, opts);
    if child.status != process::RUNNING {
        print("the child did not start: ");
        print(child.status);
        exit(1);
    }

    var text: u8[>..] = [];
    var errors: u8[>..] = [];
    while process::alive(child) {
        process::read(child, text, errors);
    }
    let outcome = process::wait(child, 5000);
    if outcome.status != process::ENDED {
        print("the child did not end: ");
        print(outcome.status);
        process::free(child);
        exit(1);
    }
    process::read(child, text, errors);
    process::free(child);
    print(text);
    return 0;
}
