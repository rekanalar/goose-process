// The rate check of the process package. It starts a short program many
// times and it prints the rate. The file stays outside the gate.
//
//   goose build --debug test/measure.goose -o <file>
//   <file>

import std;
import os;
import process from "..";

fn main() {
    var args: const u8[:][>..] = [];
    var name = "echo";
    if is_windows() {
        name = "cmd";
        args.push("/c");
        args.push("echo");
    }
    args.push("x");

    var opts = process::options();
    let rounds: i64 = 200;
    let start = clock_ns();
    for i in 0..rounds {
        let r = process::run(name, args, "", opts);
        if r.status != process::ENDED {
            print("the program did not end");
            exit(1);
        }
    }
    let ms = (clock_ns() - start) / 1000000;
    print("rounds: ");
    print(rounds);
    print(" ms: ");
    print(ms);
    print(" runs a second: ");
    if ms > 0 {
        print(rounds * 1000 / ms);
    } else {
        print("more than 1000");
    }
    return 0;
}

// The measure runs on Windows and on Unix.
fn is_windows() -> bool {
    var value: u8[>..] = [];
    if !env("OS", value) {
        return false;
    }
    return value == "Windows_NT";
}
