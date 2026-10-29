"""Remove experimental wording from the app's adapter labels.

`adapterLabel` was written while the Linksfield protocol was still being
reverse-engineered. It is now the production path, so "(试验中)" in a customer
build reads as a warning about the only thing that works.
"""
import io

PATH = "lib/api.dart"
src = io.open(PATH, encoding="utf-8").read()

PAIRS = [
    ('return "Linksfield（试验中）";', 'return "Linksfield";'),
    ('return "BeeSIM（已停用）";', 'return "BeeSIM";'),
    ('return "模拟（仅测试）";', 'return "模拟";'),
    ('return "标准 eUICC（SGP.22）";', 'return "标准 eUICC（SGP.22）";'),
]

missed = []
for old, new in PAIRS:
    if old in src:
        src = src.replace(old, new)
    else:
        missed.append(old[:60])

io.open(PATH, "w", encoding="utf-8").write(src)
print("applied", len(PAIRS) - len(missed), "/", len(PAIRS))
for m in missed:
    print("  MISSED:", m)
