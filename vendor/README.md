# subprocess.h

`subprocess.h`, copied without change from
[sheredom/subprocess.h](https://github.com/sheredom/subprocess.h) at commit
`dd28a9cca5eb6783de8bf7879599e04197472fe0`.

The library starts a process with a working directory and an environment. It
reads the output of the process and waits for its exit code. It works on
Windows, on Linux and on macOS.

The Goose compiler ships the same header in `third_party/subprocess/`. The
compiler uses it to start the C compiler, cmake and git.

The license is public domain, under the Unlicense. The full text sits at the
top of the file.

To update the header, copy the file from a newer commit. Record that commit
here.
