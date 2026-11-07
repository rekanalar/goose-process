// The example of a chain. The output of the first child becomes the input
// of the second child. No shell runs between them. The caller copies the
// bytes.

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
    if is_windows() {
        // The chain needs a shell of Unix for its two small programs. The
        // example of the live child shows the handle on Windows.
        print("the chain example needs a unix shell");
        return 0;
    }

    var first_args: const u8[:][>..] = [];
    first_args.push("-c");
    first_args.push("echo count me");
    var opts = process::options();
    let first = process::spawn("sh", first_args, opts);

    var text: u8[>..] = [];
    var errors: u8[>..] = [];
    while process::alive(first) {
        process::read(first, text, errors);
    }
    let one = process::wait(first, 5000);
    if one.status != process::ENDED {
        print("the first child failed: ");
        print(one.status);
        process::free(first);
        exit(1);
    }
    process::read(first, text, errors);
    process::free(first);

    var second_args: const u8[:][>..] = [];
    second_args.push("-c");
    second_args.push("wc -c");
    let second = process::spawn("sh", second_args, opts);
    process::write(second, text);
    process::close_input(second);
    var answer: u8[>..] = [];
    while process::alive(second) {
        process::read(second, answer, errors);
    }
    let two = process::wait(second, 5000);
    if two.status != process::ENDED {
        print("the second child failed: ");
        print(two.status);
        process::free(second);
        exit(1);
    }
    process::read(second, answer, errors);
    process::free(second);
    print(answer);
    return 0;
}
