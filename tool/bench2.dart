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
  print('cost of one keystroke followed by a line query (the real typing path)\n');
  print('${'size'.padRight(8)}${'lines'.padLeft(9)}${'edit+charToLine'.padLeft(18)}');
  for (final e in {'10 KB': 10240, '100 KB': 102400, '1 MB': 1048576, '10 MB': 10485760}.entries) {
    final doc = makeDoc(e.value);
    final r = RopeBridge.create(initialText: doc);
    var cur = r.lenChars().toInt() ~/ 2;
    final lines = r.lenLines().toInt();
    final iters = e.value > 2000000 ? 300 : 3000;
    us(100, () { r.insert(charIdx: big(cur), text: 'x'); cur++; r.charToLine(charIdx: big(cur)); });
    final t = us(iters, () {
      r.insert(charIdx: big(cur), text: 'x'); cur++;
      r.charToLine(charIdx: big(cur));
    });
    print('${e.key.padRight(8)}${lines.toString().padLeft(9)}${t.toStringAsFixed(1).padLeft(18)}');
  }
}
