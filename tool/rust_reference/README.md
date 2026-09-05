# Differential test against the Rust original

The pure-Dart core in `lib/src/core/` is a reimplementation of the
`flutter_rust_bridge` binding that `code_forge` 10.8.0 shipped. These two
programs are how it was checked: they drive the *Rust* implementation through
the same operations as `tool/diff_harness.dart` drives the Dart one, and the two
outputs are compared byte for byte.

At the time of writing they agree on **all 13,939 lines of output** — eleven
documents covering empty, no-trailing-newline, CRLF, blank-line, brace-nested,
HTML-tag, colon-indented, RTL, mixed-direction and non-ASCII text, plus a
300-operation randomised `LayoutMap` script.

## Running it

The Rust side needs the published package in the pub cache and a Rust toolchain.
The crate only builds `cdylib`/`staticlib`, so it has to be copied and given an
`rlib` crate type before it can be linked as a dependency:

```bash
CF=~/.pub-cache/hosted/pub.dev/code_forge-10.8.0
cp -r "$CF/rust" /tmp/cfrust
sed -i 's/crate-type = \["cdylib", "staticlib"\]/crate-type = ["cdylib", "staticlib", "rlib"]/' \
  /tmp/cfrust/Cargo.toml

cargo new /tmp/ref && cd /tmp/ref
printf 'code_forge = { path = "/tmp/cfrust" }\n' >> Cargo.toml
cp <this dir>/main.rs src/main.rs
cargo run --release > /tmp/rust.txt

cd <package root>
dart run tool/diff_harness.dart > /tmp/dart.txt
diff /tmp/rust.txt /tmp/dart.txt && echo "identical"
```

`probe.rs` is the smaller program used to pin down the `zed-sum-tree` cursor
semantics — in particular the `Bias::Left` off-by-one in `insertLine`,
`removeLine` and `updateLine` that `lib/src/core/editor.dart` reproduces
deliberately. Run it the same way.

## What is *not* expected to match

Documents containing astral-plane characters. `ropey` indexes by Unicode scalar
value; the Dart core indexes by UTF-16 code unit, deliberately — see the library
comment on `lib/src/core/rope.dart`. For text inside the BMP the two schemes
produce identical indices, which is why every document in `main.rs` stays there.
