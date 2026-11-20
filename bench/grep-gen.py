# Generates the data sets for bench/grep-matrix.sh: python3 -I grep-gen.py DIR
import os, random, sys
d = sys.argv[1]
os.makedirs(d, exist_ok=True)
rnd = random.Random(12345)
letters = "abcdefghijklmnopqrstuvwxy"  # no z: "zqxjv" stays rare
vocab = ["".join(rnd.choice(letters) for _ in range(rnd.randint(2, 9))) for _ in range(5000)]
vocab[:6] = ["the", "two", "and", "of", "to", "in"]
weights = [1.0 / (i + 1) for i in range(len(vocab))]


def lines(nbytes, vocab, rare="zqxjv", every=100000):
    out, size, n = [], 0, 0
    while size < nbytes:
        ws = rnd.choices(vocab, weights, k=rnd.randint(4, 14))
        n += 1
        if n % every == 0:
            ws.insert(rnd.randint(0, len(ws)), rare)
        if n % 5000 == 0:
            ws.append("a.b-c_d%d" % n)  # for classes and numbers
        s = " ".join(ws) + "\n"
        out.append(s)
        size += len(s.encode())
    return "".join(out)


def write(name, nbytes, vocab):
    with open(os.path.join(d, name), "w", encoding="utf-8") as f:
        f.write(lines(nbytes, vocab))


write("big.txt", 100 << 20, vocab)
write("mid.txt", 10 << 20, vocab)
uv = [w.replace("e", "é").replace("o", "ö").replace("k", "日本") if i % 3 == 0 else w for i, w in enumerate(vocab)]
write("utf8.txt", 10 << 20, uv)
# 3000 words absent from the vocabulary except a few (about 300 matching lines)
vs = set(vocab)
words = []
while len(words) < 3000:
    w = "".join(rnd.choice(letters) for _ in range(rnd.randint(5, 6)))
    if w not in vs:
        words.append(w)
open(os.path.join(d, "words3000.txt"), "w").write("\n".join(words) + "\n")
open(os.path.join(d, "words1000.txt"), "w").write("\n".join(words[:1000]) + "\n")
open(os.path.join(d, "words10.txt"), "w").write("\n".join(words[:5] + vocab[10:15]) + "\n")
# the tree: 10000 small files
for i in range(10000):
    sub = os.path.join(d, "tree", "d%02d" % (i % 100))
    os.makedirs(sub, exist_ok=True)
    ext = (".txt", ".c", ".md", ".h")[i % 4]
    with open(os.path.join(sub, "f%05d%s" % (i, ext)), "w") as f:
        f.write(lines(2000, vocab, every=20))
