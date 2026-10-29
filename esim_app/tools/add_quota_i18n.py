import io

PATH = 'lib/i18n.dart'
src = io.open(PATH, encoding='utf-8').read()

ENTRIES = r'''
  String cwStatusCheckQuota() => _t({AppLang.en: 'Checking the card quota…', AppLang.zh: '正在校验写卡配额…', AppLang.ja: 'クォータを確認中…', AppLang.ko: '할당량 확인 중…', AppLang.th: 'กำลังตรวจสอบโควตา…', AppLang.vi: 'Đang kiểm tra hạn mức…'});
  String cwQuotaLine(int used, int cap) => _t({AppLang.en: 'Card quota: $used / $cap used', AppLang.zh: '写卡配额：已用 $used / 上限 $cap', AppLang.ja: 'クォータ：$used / $cap 使用済み', AppLang.ko: '할당량: $used / $cap 사용', AppLang.th: 'โควตา: ใช้ $used / $cap', AppLang.vi: 'Hạn mức: đã dùng $used / $cap'});
  String cwQuotaCheckFailed(String e) => _t({AppLang.en: 'Quota could not be verified ($e); continuing without the server check.', AppLang.zh: '配额校验失败（$e），本次未做服务器校验', AppLang.ja: 'クォータを確認できません（$e）。サーバー確認なしで続行します。', AppLang.ko: '할당량을 확인하지 못했습니다($e). 서버 확인 없이 진행합니다.', AppLang.th: 'ตรวจสอบโควตาไม่สำเร็จ ($e) ดำเนินการต่อโดยไม่ตรวจกับเซิร์ฟเวอร์', AppLang.vi: 'Không xác minh được hạn mức ($e); tiếp tục mà không kiểm tra với máy chủ.'});
  String get cwQuotaTitle => _t({AppLang.en: 'Quota', AppLang.zh: '配额', AppLang.ja: 'クォータ', AppLang.ko: '할당량', AppLang.th: 'โควตา', AppLang.vi: 'Hạn mức'});
'''

marker = "  // order status labels"
assert marker in src
src = src.replace(marker, ENTRIES + "\n" + marker, 1)
io.open(PATH, 'w', encoding='utf-8').write(src)
print('quota i18n added')
