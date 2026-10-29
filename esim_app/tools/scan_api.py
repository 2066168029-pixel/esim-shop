import io
import re

s = io.open('lib/api.dart', encoding='utf-8').read()
print('api.dart lines:', len(s.split('\n')))
keys = sorted(set(re.findall(r'"(/api/[^"]*)"', s)))
print('endpoints:')
for k in keys:
    print('  ', k)

# 找 baseUrl 和服务端仓库线索
for i, l in enumerate(s.split('\n'), 1):
    if 'baseUrl' in l or 'http' in l.lower():
        print(i, l.strip()[:110])
