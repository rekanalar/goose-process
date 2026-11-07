// The example of the process package. It runs a small program and prints
// what that program says.

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
    args.push("hello from goose-process");

    var opts = process::options();
    opts.timeout_ms = 5000;

    let r = process::run(name, args, "", opts);
    if r.status != process::ENDED {
        print("the program did not end: ");
        print(r.status);
        exit(1);
    }
    if r.code != 0 {
        print("the program failed with the code ");
        print(r.code);
        exit(1);
    }
    print(r.output);
    return 0;
}
