// Micro-benchmark of the pure-Dart core. Run: dart run tool/bench.dart
import 'package:code_forge/src/core/rope.dart';

BigInt big(int v) => BigInt.from(v);

String makeDoc(int bytes) {
  const line = 'const someIdentifier: number = compute(a, b) + offset[i];\n';
  final b = StringBuffer();
  while (b.length < bytes) {
    b.write(line);
  }
  return b.toString();
}

double us(int iters, void Function() f) {
  final sw = Stopwatch()..start();
  for (var i = 0; i < iters; i++) {
    f();
  }
  return sw.elapsedMicroseconds / iters;
}

void main() {
  print('pure-Dart RopeBridge — microseconds per operation\n');
  print('${'size'.padRight(8)}${'type @cursor'.padLeft(14)}'
      '${'getText cold'.padLeft(14)}${'getText warm'.padLeft(14)}'
      '${'charToLine'.padLeft(12)}${'line()'.padLeft(10)}');

  for (final e in {'10 KB': 10240, '100 KB': 102400, '1 MB': 1048576, '10 MB': 10485760}.entries) {
    final doc = makeDoc(e.value);
    final r = RopeBridge.create(initialText: doc);
    final n = r.lenChars().toInt();

    var cur = n ~/ 2;
    us(5000, () { r.insert(charIdx: big(cur), text: 'x'); cur++; });  // warm up
    final typing = us(20000, () { r.insert(charIdx: big(cur), text: 'x'); cur++; });

    // Invalidate at the end so the gap does not move: this measures
    // materialising the document, not a memmove across it.
    final r2 = RopeBridge.create(initialText: doc);
    var end = n;
    r2.insert(charIdx: big(end), text: 'x');
    r2.getText();
    final cold = us(n > 2000000 ? 20 : 200, () {
      r2.insert(charIdx: big(++end), text: 'x');
      r2.getText();
    });

    final r3 = RopeBridge.create(initialText: doc);
    r3.getText();
    final warm = us(200000, () { r3.getText(); });

    final r4 = RopeBridge.create(initialText: doc);
    r4.lenLines();
    var acc = 0;
    final c2l = us(200000, () { acc += r4.charToLine(charIdx: big(acc % n)).toInt(); });
    final lines = r4.lenLines().toInt();
    var li = 0;
    final line = us(200000, () { r4.line(lineIdx: big(li++ % lines)); });
    if (acc < 0) return;

    print('${e.key.padRight(8)}${typing.toStringAsFixed(2).padLeft(14)}'
        '${cold.toStringAsFixed(1).padLeft(14)}${warm.toStringAsFixed(3).padLeft(14)}'
        '${c2l.toStringAsFixed(3).padLeft(12)}${line.toStringAsFixed(3).padLeft(10)}');
  }
}
