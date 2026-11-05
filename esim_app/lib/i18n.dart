/// Supported app languages.
enum AppLang { en, zh, ja, ko, th, vi }

extension AppLangInfo on AppLang {
  String get code => const {AppLang.en: 'en', AppLang.zh: 'zh', AppLang.ja: 'ja', AppLang.ko: 'ko', AppLang.th: 'th', AppLang.vi: 'vi'}[this]!;
  String get label => const {AppLang.en: 'English', AppLang.zh: '中文', AppLang.ja: '日本語', AppLang.ko: '한국어', AppLang.th: 'ไทย', AppLang.vi: 'Tiếng Việt'}[this]!;
  String get short => const {AppLang.en: 'EN', AppLang.zh: '中', AppLang.ja: '日', AppLang.ko: '한', AppLang.th: 'ท', AppLang.vi: 'VI'}[this]!;
}

/// All UI strings for the app, keyed by a stable id.
/// Falls back to English when a key is missing for a language.
class L {
  final AppLang lang;
  final Map<String, String> overrides;
  const L(this.lang, {this.overrides = const {}});

  /// Resolve a string: admin override (by key) wins, else built-in translation.
  String _t(Map<AppLang, String> m, [String? key]) {
    if (key != null && overrides.containsKey(key)) return overrides[key]!;
    return m[lang] ?? m[AppLang.en]!;
  }

  // bottom nav
  String get navHome => _t({AppLang.en: 'Home', AppLang.zh: '首页', AppLang.ja: 'ホーム', AppLang.ko: '홈', AppLang.th: 'หน้าแรก', AppLang.vi: 'Trang chủ'});
  String get navPlans => _t({AppLang.en: 'Plans', AppLang.zh: '套餐', AppLang.ja: 'プラン', AppLang.ko: '요금제', AppLang.th: 'แพ็กเกจ', AppLang.vi: 'Gói cước'});
  String get navActivate => _t({AppLang.en: 'Activate', AppLang.zh: '激活', AppLang.ja: 'アクティベート', AppLang.ko: '활성화', AppLang.th: 'เปิดใช้งาน', AppLang.vi: 'Kích hoạt'});
  String get navOrders => _t({AppLang.en: 'Orders', AppLang.zh: '订单', AppLang.ja: '注文', AppLang.ko: '주문', AppLang.th: 'คำสั่งซื้อ', AppLang.vi: 'Đơn hàng'});
  String get navMe => _t({AppLang.en: 'Me', AppLang.zh: '我的', AppLang.ja: 'マイ', AppLang.ko: '내 정보', AppLang.th: 'ของฉัน', AppLang.vi: 'Tôi'});

  // home
  String get travelEsim => _t({AppLang.en: 'Travel eSIM', AppLang.zh: '旅行 eSIM', AppLang.ja: 'トラベル eSIM', AppLang.ko: '여행 eSIM', AppLang.th: 'eSIM ท่องเที่ยว', AppLang.vi: 'eSIM Du lịch'});
  String get tagline => _t({AppLang.en: 'Activate instantly, stay online worldwide', AppLang.zh: '落地即用 · 全球上网', AppLang.ja: '到着後すぐ使える・世界中でオンライン', AppLang.ko: '도착 즉시 사용 · 전 세계 인터넷', AppLang.th: 'ใช้งานทันที ออนไลน์ทั่วโลก', AppLang.vi: 'Kích hoạt ngay, online toàn cầu'});
  String get myEsim => _t({AppLang.en: 'My eSIM', AppLang.zh: '我的 eSIM', AppLang.ja: 'マイ eSIM', AppLang.ko: '내 eSIM', AppLang.th: 'eSIM ของฉัน', AppLang.vi: 'eSIM của tôi'});
  String get notLoggedIn => _t({AppLang.en: 'Not signed in', AppLang.zh: '未登录', AppLang.ja: '未ログイン', AppLang.ko: '로그인 안 됨', AppLang.th: 'ยังไม่เข้าสู่ระบบ', AppLang.vi: 'Chưa đăng nhập'});
  String get noEsimYet => _t({AppLang.en: 'No eSIM yet?', AppLang.zh: '还没有 eSIM？', AppLang.ja: 'まだ eSIM がない？', AppLang.ko: '아직 eSIM이 없나요?', AppLang.th: 'ยังไม่มี eSIM?', AppLang.vi: 'Chưa có eSIM?'});
  String get pickDest => _t({AppLang.en: 'Pick a destination, activate now', AppLang.zh: '选一个目的地，立即开通', AppLang.ja: '目的地を選んで今すぐ開通', AppLang.ko: '목적지를 골라 지금 개통', AppLang.th: 'เลือกจุดหมาย เปิดใช้ทันที', AppLang.vi: 'Chọn điểm đến, kích hoạt ngay'});
  String get buyEsim => _t({AppLang.en: 'Buy eSIM', AppLang.zh: '购买 eSIM', AppLang.ja: 'eSIM 購入', AppLang.ko: 'eSIM 구매', AppLang.th: 'ซื้อ eSIM', AppLang.vi: 'Mua eSIM'});
  String get myPlans => _t({AppLang.en: 'My Plans', AppLang.zh: '我的套餐', AppLang.ja: 'マイプラン', AppLang.ko: '내 요금제', AppLang.th: 'แพ็กเกจของฉัน', AppLang.vi: 'Gói của tôi'});
  String get scanQr => _t({AppLang.en: 'Scan QR', AppLang.zh: '扫码激活', AppLang.ja: 'QR スキャン', AppLang.ko: 'QR 스캔', AppLang.th: 'สแกน QR', AppLang.vi: 'Quét QR'});
  String get myOrders => _t({AppLang.en: 'My Orders', AppLang.zh: '我的订单', AppLang.ja: 'マイ注文', AppLang.ko: '내 주문', AppLang.th: 'คำสั่งซื้อ', AppLang.vi: 'Đơn của tôi'});
  String get helpCenter => _t({AppLang.en: 'Help Center', AppLang.zh: '客服中心', AppLang.ja: 'ヘルプ', AppLang.ko: '고객센터', AppLang.th: 'ศูนย์ช่วยเหลือ', AppLang.vi: 'Trung tâm hỗ trợ'});
  String get popularPlans => _t({AppLang.en: 'Popular Plans', AppLang.zh: '热门套餐', AppLang.ja: '人気プラン', AppLang.ko: '인기 요금제', AppLang.th: 'แพ็กเกจยอดนิยม', AppLang.vi: 'Gói phổ biến'});
  String get viewAll => _t({AppLang.en: 'View all', AppLang.zh: '查看全部', AppLang.ja: 'すべて見る', AppLang.ko: '전체 보기', AppLang.th: 'ดูทั้งหมด', AppLang.vi: 'Xem tất cả'});

  // plans
  String get choosePlan => _t({AppLang.en: 'Choose Your eSIM Plan', AppLang.zh: '选择你的 eSIM 套餐', AppLang.ja: 'eSIM プランを選ぶ', AppLang.ko: 'eSIM 요금제 선택', AppLang.th: 'เลือกแพ็กเกจ eSIM', AppLang.vi: 'Chọn gói eSIM'});
  String get searchDest => _t({AppLang.en: 'Search destination', AppLang.zh: '搜索目的地', AppLang.ja: '目的地を検索', AppLang.ko: '목적지 검색', AppLang.th: 'ค้นหาจุดหมาย', AppLang.vi: 'Tìm điểm đến'});
  String get days => _t({AppLang.en: 'Days', AppLang.zh: '天', AppLang.ja: '日', AppLang.ko: '일', AppLang.th: 'วัน', AppLang.vi: 'ngày'});
  String get allFilter => _t({AppLang.en: 'All', AppLang.zh: '全部', AppLang.ja: 'すべて', AppLang.ko: '전체', AppLang.th: 'ทั้งหมด', AppLang.vi: 'Tất cả'});
  String get buy => _t({AppLang.en: 'Buy', AppLang.zh: '购买', AppLang.ja: '購入', AppLang.ko: '구매', AppLang.th: 'ซื้อ', AppLang.vi: 'Mua'});
  String get bestSeller => _t({AppLang.en: 'Best Seller', AppLang.zh: '热销', AppLang.ja: 'ベストセラー', AppLang.ko: '베스트셀러', AppLang.th: 'ขายดี', AppLang.vi: 'Bán chạy'});
  String get popular => _t({AppLang.en: 'Popular', AppLang.zh: '优选', AppLang.ja: '人気', AppLang.ko: '인기', AppLang.th: 'ยอดนิยม', AppLang.vi: 'Phổ biến'});
  String get budget => _t({AppLang.en: 'Budget', AppLang.zh: '限时', AppLang.ja: 'お得', AppLang.ko: '특가', AppLang.th: 'ประหยัด', AppLang.vi: 'Tiết kiệm'});
  String get noPhysicalSim => _t({AppLang.en: 'No Physical SIM', AppLang.zh: '无需实体卡', AppLang.ja: '物理 SIM 不要', AppLang.ko: '실물 SIM 불필요', AppLang.th: 'ไม่ต้องใช้ SIM จริง', AppLang.vi: 'Không cần SIM vật lý'});
  String get instantActivation => _t({AppLang.en: 'Instant Activation', AppLang.zh: '扫码激活', AppLang.ja: '即時アクティベート', AppLang.ko: '즉시 활성화', AppLang.th: 'เปิดใช้ทันที', AppLang.vi: 'Kích hoạt tức thì'});
  String get nationwide => _t({AppLang.en: 'Nationwide Coverage', AppLang.zh: '全境覆盖', AppLang.ja: '全国カバー', AppLang.ko: '전국 커버리지', AppLang.th: 'ครอบคลุมทั่วประเทศ', AppLang.vi: 'Phủ toàn quốc'});
  String get support247 => _t({AppLang.en: '24/7 Support', AppLang.zh: '24h 客服', AppLang.ja: '24時間サポート', AppLang.ko: '24시간 지원', AppLang.th: 'ซัพพอร์ต 24 ชม.', AppLang.vi: 'Hỗ trợ 24/7'});

  // activate
  String get activateEsim => _t({AppLang.en: 'Activate eSIM', AppLang.zh: '激活 eSIM', AppLang.ja: 'eSIM をアクティベート', AppLang.ko: 'eSIM 활성화', AppLang.th: 'เปิดใช้งาน eSIM', AppLang.vi: 'Kích hoạt eSIM'});
  String get scanYourQr => _t({AppLang.en: 'Scan Your QR Code', AppLang.zh: '扫描你的二维码', AppLang.ja: 'QR コードをスキャン', AppLang.ko: 'QR 코드 스캔', AppLang.th: 'สแกน QR ของคุณ', AppLang.vi: 'Quét mã QR'});
  String get cameraRequired => _t({AppLang.en: 'Camera access required', AppLang.zh: '需要相机权限', AppLang.ja: 'カメラ権限が必要', AppLang.ko: '카메라 권한 필요', AppLang.th: 'ต้องเข้าถึงกล้อง', AppLang.vi: 'Cần quyền camera'});
  String get enterCode => _t({AppLang.en: 'Enter ICCID', AppLang.zh: '输入 ICCID', AppLang.ja: 'ICCID を入力', AppLang.ko: 'ICCID 입력', AppLang.th: 'ป้อน ICCID', AppLang.vi: 'Nhập ICCID'});
  String get typeCode => _t({AppLang.en: 'Enter your ICCID', AppLang.zh: '请输入您的 ICCID', AppLang.ja: 'ICCID を入力してください', AppLang.ko: 'ICCID를 입력하세요', AppLang.th: 'กรอก ICCID ของคุณ', AppLang.vi: 'Nhập ICCID của bạn'});
  String get confirmBtn => _t({AppLang.en: 'Confirm', AppLang.zh: '确认', AppLang.ja: '確認', AppLang.ko: '확인', AppLang.th: 'ยืนยัน', AppLang.vi: 'Xác nhận'});
  String get stepScan => _t({AppLang.en: 'Scan', AppLang.zh: '扫码', AppLang.ja: 'スキャン', AppLang.ko: '스캔', AppLang.th: 'สแกน', AppLang.vi: 'Quét'});
  String get stepConfirm => _t({AppLang.en: 'Confirm', AppLang.zh: '确认', AppLang.ja: '確認', AppLang.ko: '확인', AppLang.th: 'ยืนยัน', AppLang.vi: 'Xác nhận'});
  String get stepConnect => _t({AppLang.en: 'Connect', AppLang.zh: '连接', AppLang.ja: '接続', AppLang.ko: '연결', AppLang.th: 'เชื่อมต่อ', AppLang.vi: 'Kết nối'});
  String get startActivation => _t({AppLang.en: 'Start Activation', AppLang.zh: '开始激活', AppLang.ja: 'アクティベート開始', AppLang.ko: '활성화 시작', AppLang.th: 'เริ่มเปิดใช้', AppLang.vi: 'Bắt đầu kích hoạt'});

  // orders
  String get tabAll => _t({AppLang.en: 'All', AppLang.zh: '全部', AppLang.ja: 'すべて', AppLang.ko: '전체', AppLang.th: 'ทั้งหมด', AppLang.vi: 'Tất cả'});
  String get tabValid => _t({AppLang.en: 'Active', AppLang.zh: '有效', AppLang.ja: '有効', AppLang.ko: '유효', AppLang.th: 'ใช้งานได้', AppLang.vi: 'Còn hiệu lực'});
  String get tabExpired => _t({AppLang.en: 'Expired', AppLang.zh: '已过期', AppLang.ja: '期限切れ', AppLang.ko: '만료', AppLang.th: 'หมดอายุ', AppLang.vi: 'Hết hạn'});
  String get tabPending => _t({AppLang.en: 'Pending', AppLang.zh: '待激活', AppLang.ja: '保留中', AppLang.ko: '대기', AppLang.th: 'รอดำเนินการ', AppLang.vi: 'Chờ kích hoạt'});
  String get dataBalance => _t({AppLang.en: 'Data Balance', AppLang.zh: '剩余流量', AppLang.ja: '残りデータ', AppLang.ko: '남은 데이터', AppLang.th: 'ข้อมูลคงเหลือ', AppLang.vi: 'Dung lượng còn'});
  String get used => _t({AppLang.en: 'Used', AppLang.zh: '已用', AppLang.ja: '使用済み', AppLang.ko: '사용', AppLang.th: 'ใช้ไป', AppLang.vi: 'Đã dùng'});
  String get expiresIn => _t({AppLang.en: 'Expires in', AppLang.zh: '剩余', AppLang.ja: '残り', AppLang.ko: '만료까지', AppLang.th: 'หมดอายุใน', AppLang.vi: 'Hết hạn sau'});
  String get viewQr => _t({AppLang.en: 'View QR Code', AppLang.zh: '查看二维码', AppLang.ja: 'QR を表示', AppLang.ko: 'QR 보기', AppLang.th: 'ดู QR', AppLang.vi: 'Xem QR'});
  String get buyAgain => _t({AppLang.en: 'Buy Again', AppLang.zh: '再次购买', AppLang.ja: '再購入', AppLang.ko: '다시 구매', AppLang.th: 'ซื้ออีก', AppLang.vi: 'Mua lại'});
  String get help => _t({AppLang.en: 'Help', AppLang.zh: '帮助', AppLang.ja: 'ヘルプ', AppLang.ko: '도움말', AppLang.th: 'ช่วยเหลือ', AppLang.vi: 'Trợ giúp'});
  String get noOrders => _t({AppLang.en: 'No orders yet', AppLang.zh: '暂无订单', AppLang.ja: '注文はありません', AppLang.ko: '주문이 없습니다', AppLang.th: 'ยังไม่มีคำสั่งซื้อ', AppLang.vi: 'Chưa có đơn hàng'});

  // me
  String get activePlans => _t({AppLang.en: 'Active Plans', AppLang.zh: '活跃套餐', AppLang.ja: '有効プラン', AppLang.ko: '활성 요금제', AppLang.th: 'แพ็กเกจที่ใช้งาน', AppLang.vi: 'Gói đang dùng'});
  String get totalData => _t({AppLang.en: 'Total Data', AppLang.zh: '总流量', AppLang.ja: '総データ', AppLang.ko: '총 데이터', AppLang.th: 'ข้อมูลทั้งหมด', AppLang.vi: 'Tổng dung lượng'});
  String get dataUsed => _t({AppLang.en: 'Used', AppLang.zh: '已使用', AppLang.ja: '使用済み', AppLang.ko: '사용량', AppLang.th: 'ใช้ไป', AppLang.vi: 'Đã dùng'});
  String get payment => _t({AppLang.en: 'Payment Methods', AppLang.zh: '支付方式', AppLang.ja: '支払い方法', AppLang.ko: '결제 수단', AppLang.th: 'วิธีชำระเงิน', AppLang.vi: 'Thanh toán'});
  // refer a friend
  String get inviteFriends => _t({AppLang.en: 'Invite Friends', AppLang.zh: '邀请好友', AppLang.ja: '友達を招待', AppLang.ko: '?? ??', AppLang.th: 'ชวนเพื่อน', AppLang.vi: 'M?i b?n b?'});
  String get inviteSubtitle => _t({AppLang.en: 'Friends get 5% off their first order', AppLang.zh: '好友下单立享 5% 优惠', AppLang.ja: '???????? 5% ????', AppLang.ko: '?? ?? ?? 5% ??', AppLang.th: '???????? 5% ???????????', AppLang.vi: 'B?n b? gi?m 5% ??n ??u ti?n'});
  String get cashVoucher => _t({AppLang.en: 'Cash voucher', AppLang.zh: '现金券', AppLang.ja: '現金クーポン', AppLang.ko: '?? ??', AppLang.th: 'คูปองเงินสด', AppLang.vi: 'Phi?u ti?n m?t'});
  String get voucherBalance => _t({AppLang.en: 'Balance', AppLang.zh: '余额', AppLang.ja: '残高', AppLang.ko: '잔액', AppLang.th: 'ยอดเงิน', AppLang.vi: 'S? d?'});
  String get voucherNote => _t({AppLang.en: 'Earn 5% of your friend\'s first order, paid in CNY', AppLang.zh: '好友首单实付金额的 5%，以人民币发放', AppLang.ja: '??? ???? 5%?? CNY????????', AppLang.ko: '?? ?? ?? 5%, CNY ???', AppLang.th: '??? 5% ?????? CNY', AppLang.vi: 'Nh?n 5% ??n h?ng ??u c?a b?n b?, b?ng CNY'});
  String get useVoucher => _t({AppLang.en: 'Use cash voucher', AppLang.zh: '使用现金券抵扣', AppLang.ja: '使用する', AppLang.ko: '?? ?? ??', AppLang.th: 'ใช้คูปอง', AppLang.vi: 'D?ng phi?u gi?m gi?'});

  String get inviteCodeOptional => _t({AppLang.en: 'Invite code (optional)', AppLang.zh: '邀请码（选填）', AppLang.ja: '???ID?????', AppLang.ko: '?? ??(??)', AppLang.th: '?????????(?????)', AppLang.vi: 'M? m?i (kh?ng b?t bu?c)'});
  String get inviteCodeHint => _t({AppLang.en: 'Enter it to get 5% off your first order', AppLang.zh: '塭写可享首单 5% 优惠', AppLang.ja: '??????? 5% ????', AppLang.ko: '?? ?? 5% ??', AppLang.th: '?????? 5% ???????', AppLang.vi: 'Nh?p ?? ???c gi?m 5% ??n ??u'});
  String get inviteApplied => _t({AppLang.en: 'Invite code applied', AppLang.zh: '邀请码已生效', AppLang.ja: '?????ID????', AppLang.ko: '?? ??? ?????', AppLang.th: 'ใช้รหัสเชิญแล้ว', AppLang.vi: '?? ?p d?ng m? m?i'});

  String get myInviteCode => _t({AppLang.en: 'My invite code', AppLang.zh: '我的邀请码', AppLang.ja: '?????ID', AppLang.ko: '?? ?? ??', AppLang.th: 'รหัสเชิญของฉัน', AppLang.vi: 'M? m?i c?a t?i'});
  String get copyInviteCode => _t({AppLang.en: 'Copy code', AppLang.zh: '复制邀请码', AppLang.ja: 'ID ????', AppLang.ko: '?? ??', AppLang.th: 'คัดลอกรหัสเชิญ', AppLang.vi: 'Sao ch?p m?'});
  String get saved => _t({AppLang.en: 'Saved to album', AppLang.zh: '已保存到相册', AppLang.ja: '保存しました', AppLang.ko: '??? ?????', AppLang.th: 'บันทึกแล้ว', AppLang.vi: '?? l?u v?o th? vi?n'});
  String get invitedFriends => _t({AppLang.en: 'Invited', AppLang.zh: '已邀请', AppLang.ja: '招待人数', AppLang.ko: '?? ??', AppLang.th: 'จำนวนที่เชิญ', AppLang.vi: '?? m?i'});
  String get qualifiedFriends => _t({AppLang.en: 'Rewarded', AppLang.zh: '已达标', AppLang.ja: '成立人数', AppLang.ko: '?? ??', AppLang.th: 'ที่สำเร็จ', AppLang.vi: '?? ??t'});
  String get savePoster => _t({AppLang.en: 'Save poster', AppLang.zh: '保存海报', AppLang.ja: 'ポスターを保存', AppLang.ko: '??? ??', AppLang.th: 'บันทึกโปสเตอร์', AppLang.vi: 'L?u poster'});
  String get sharePoster => _t({AppLang.en: 'Share poster', AppLang.zh: '分享海报', AppLang.ja: 'ポスターを共有', AppLang.ko: '??? ??', AppLang.th: 'แชร์โปสเตอร์', AppLang.vi: 'Chia s? poster'});

  String get qrCode => _t({AppLang.en: 'QR Code', AppLang.zh: '二维码', AppLang.ja: 'QR コード', AppLang.ko: 'QR 코드', AppLang.th: 'คิวอาร์โค้ด', AppLang.vi: 'Mã QR'});
  String get language => _t({AppLang.en: 'Language', AppLang.zh: '语言', AppLang.ja: '言語', AppLang.ko: '언어', AppLang.th: 'ภาษา', AppLang.vi: 'Ngôn ngữ'});
  String get currency => _t({AppLang.en: 'Currency', AppLang.zh: '币种', AppLang.ja: '通貨', AppLang.ko: '통화', AppLang.th: 'สกุลเงิน', AppLang.vi: 'Tiền tệ'});
  String get faq => _t({AppLang.en: 'FAQ', AppLang.zh: '常见问题', AppLang.ja: 'よくある質問', AppLang.ko: '자주 묻는 질문', AppLang.th: 'คำถามที่พบบ่อย', AppLang.vi: 'Câu hỏi thường gặp'});
  String get settings => _t({AppLang.en: 'Settings', AppLang.zh: '设置', AppLang.ja: '設定', AppLang.ko: '설정', AppLang.th: 'ตั้งค่า', AppLang.vi: 'Cài đặt'});
  String get aboutUs => _t({AppLang.en: 'About Us', AppLang.zh: '关于我们', AppLang.ja: '会社概要', AppLang.ko: '회사 소개', AppLang.th: 'เกี่ยวกับเรา', AppLang.vi: 'Về chúng tôi'});
  String get privacy => _t({AppLang.en: 'Privacy Policy', AppLang.zh: '隐私政策', AppLang.ja: 'プライバシー', AppLang.ko: '개인정보', AppLang.th: 'ความเป็นส่วนตัว', AppLang.vi: 'Quyền riêng tư'});
  String get notifications => _t({AppLang.en: 'Notification', AppLang.zh: '通知设置', AppLang.ja: '通知', AppLang.ko: '알림', AppLang.th: 'การแจ้งเตือน', AppLang.vi: 'Thông báo'});
  String get logOut => _t({AppLang.en: 'Log Out', AppLang.zh: '退出登录', AppLang.ja: 'ログアウト', AppLang.ko: '로그아웃', AppLang.th: 'ออกจากระบบ', AppLang.vi: 'Đăng xuất'});
  String get changePassword => _t({AppLang.en: 'Change password', AppLang.zh: '修改密码', AppLang.ja: 'パスワード変更', AppLang.ko: '비밀번호 변경', AppLang.th: 'เปลี่ยนรหัสผ่าน', AppLang.vi: 'Đổi mật khẩu'});
  String get logIn => _t({AppLang.en: 'Sign In', AppLang.zh: '登录', AppLang.ja: 'ログイン', AppLang.ko: '로그인', AppLang.th: 'เข้าสู่ระบบ', AppLang.vi: 'Đăng nhập'});
  String get member => _t({AppLang.en: 'Member', AppLang.zh: '会员', AppLang.ja: 'メンバー', AppLang.ko: '멤버', AppLang.th: 'สมาชิก', AppLang.vi: 'Thành viên'});
  String get memberBadge => _t({AppLang.en: 'Onlylink Member', AppLang.zh: 'Onlylink 会员', AppLang.ja: 'Onlylink メンバー', AppLang.ko: 'Onlylink 멤버', AppLang.th: 'สมาชิก Onlylink', AppLang.vi: 'Thành viên Onlylink'});

  // cart / checkout
  String get cart => _t({AppLang.en: 'Cart', AppLang.zh: '购物车', AppLang.ja: 'カート', AppLang.ko: '장바구니', AppLang.th: 'ตะกร้า', AppLang.vi: 'Giỏ hàng'});
  String get checkout => _t({AppLang.en: 'Checkout', AppLang.zh: '结算', AppLang.ja: 'お会計', AppLang.ko: '결제', AppLang.th: 'ชำระเงิน', AppLang.vi: 'Thanh toán'});
  String get total => _t({AppLang.en: 'Total', AppLang.zh: '合计', AppLang.ja: '合計', AppLang.ko: '합계', AppLang.th: 'รวม', AppLang.vi: 'Tổng'});
  String get coupon => _t({AppLang.en: 'Coupon', AppLang.zh: '优惠码', AppLang.ja: 'クーポン', AppLang.ko: '쿠폰', AppLang.th: 'คูปอง', AppLang.vi: 'Mã giảm giá'});
  String get apply => _t({AppLang.en: 'Apply', AppLang.zh: '使用', AppLang.ja: '適用', AppLang.ko: '적용', AppLang.th: 'ใช้', AppLang.vi: 'Áp dụng'});
  String get emailLabel => _t({AppLang.en: 'Email', AppLang.zh: '邮箱', AppLang.ja: 'メール', AppLang.ko: '이메일', AppLang.th: 'อีเมล', AppLang.vi: 'Email'});
  String get payNow => _t({AppLang.en: 'Pay', AppLang.zh: '支付', AppLang.ja: '支払う', AppLang.ko: '결제하기', AppLang.th: 'ชำระ', AppLang.vi: 'Thanh toán'});
  String get addedToCart => _t({AppLang.en: 'Added to cart', AppLang.zh: '已加入购物车', AppLang.ja: 'カートに追加しました', AppLang.ko: '장바구니에 담았어요', AppLang.th: 'เพิ่มลงตะกร้าแล้ว', AppLang.vi: 'Đã thêm vào giỏ'});
  String get emptyCart => _t({AppLang.en: 'Your cart is empty', AppLang.zh: '购物车是空的', AppLang.ja: 'カートは空です', AppLang.ko: '장바구니가 비었어요', AppLang.th: 'ตะกร้าว่างเปล่า', AppLang.vi: 'Giỏ hàng trống'});
  String get orderDetail => _t({AppLang.en: 'Order Detail', AppLang.zh: '订单详情', AppLang.ja: '注文詳細', AppLang.ko: '주문 상세', AppLang.th: 'รายละเอียด', AppLang.vi: 'Chi tiết đơn'});
  String get copyCode => _t({AppLang.en: 'Copy Code', AppLang.zh: '复制激活码', AppLang.ja: 'コードをコピー', AppLang.ko: '코드 복사', AppLang.th: 'คัดลอกรหัส', AppLang.vi: 'Sao chép mã'});
  String get refreshUsage => _t({AppLang.en: 'Refresh', AppLang.zh: '刷新流量', AppLang.ja: '更新', AppLang.ko: '새로고침', AppLang.th: 'รีเฟรช', AppLang.vi: 'Làm mới'});
  String get copied => _t({AppLang.en: 'Copied', AppLang.zh: '已复制', AppLang.ja: 'コピーしました', AppLang.ko: '복사됨', AppLang.th: 'คัดลอกแล้ว', AppLang.vi: 'Đã sao chép'});


  // ---------------------------------------------------------------- card writer
  // Provisioning screen. Kept in one block so the bluetooth card writer reads
  // the same language as the rest of the app instead of hard-coded Chinese.
  String get cwTitle => _t({AppLang.en: 'Write eSIM', AppLang.zh: '写入 eSIM', AppLang.ja: 'eSIM を書き込む', AppLang.ko: 'eSIM 쓰기', AppLang.th: 'เขียน eSIM', AppLang.vi: 'Ghi eSIM'});
  String get cwStepPickReader => _t({AppLang.en: 'Select reader', AppLang.zh: '选择读卡器', AppLang.ja: 'リーダーを選択', AppLang.ko: '리더 선택', AppLang.th: 'เลือกเครื่องอ่าน', AppLang.vi: 'Chọn đầu đọc'});
  String get cwReaderHint => _t({AppLang.en: 'Power the card, scan, then tap to connect', AppLang.zh: '给卡通电后扫描，点一下即可连接', AppLang.ja: 'カードに電源を入れ、スキャンして接続', AppLang.ko: '카드에 전원을 넣고 스캔한 뒤 연결', AppLang.th: 'จ่ายไฟให้การ์ด สแกน แล้วแตะเพื่อเชื่อมต่อ', AppLang.vi: 'Cấp nguồn cho thẻ, quét rồi nhấn để kết nối'});
  String get cwScanReader => _t({AppLang.en: 'Scan for reader', AppLang.zh: '扫描蓝牙读卡器', AppLang.ja: 'リーダーをスキャン', AppLang.ko: '리더 스캔', AppLang.th: 'สแกนเครื่องอ่าน', AppLang.vi: 'Quét đầu đọc'});
  String get cwStopScan => _t({AppLang.en: 'Stop scanning', AppLang.zh: '停止扫描', AppLang.ja: 'スキャン停止', AppLang.ko: '스캔 중지', AppLang.th: 'หยุดสแกน', AppLang.vi: 'Dừng quét'});
  String get cwConnect => _t({AppLang.en: 'Connect', AppLang.zh: '连接', AppLang.ja: '接続', AppLang.ko: '연결', AppLang.th: 'เชื่อมต่อ', AppLang.vi: 'Kết nối'});
  String get cwConnecting => _t({AppLang.en: 'Connecting…', AppLang.zh: '连接中…', AppLang.ja: '接続中…', AppLang.ko: '연결 중…', AppLang.th: 'กำลังเชื่อมต่อ…', AppLang.vi: 'Đang kết nối…'});
  String get cwConnected => _t({AppLang.en: 'Connected', AppLang.zh: '已连接', AppLang.ja: '接続済み', AppLang.ko: '연결됨', AppLang.th: 'เชื่อมต่อแล้ว', AppLang.vi: 'Đã kết nối'});
  String get cwDisconnect => _t({AppLang.en: 'Disconnect', AppLang.zh: '断开', AppLang.ja: '切断', AppLang.ko: '연결 해제', AppLang.th: 'ตัดการเชื่อมต่อ', AppLang.vi: 'Ngắt kết nối'});
  String get cwCardPassword => _t({AppLang.en: 'Password', AppLang.zh: 'Password', AppLang.ja: 'Password', AppLang.ko: 'Password', AppLang.th: 'Password', AppLang.vi: 'Password'});
  String get cwEnterPassword => _t({AppLang.en: 'Card password', AppLang.zh: '卡密码', AppLang.ja: 'カードパスワード', AppLang.ko: '카드 비밀번호', AppLang.th: 'รหัสผ่านบัตร', AppLang.vi: 'Mật khẩu thẻ'});
  String get cwPasswordRequired => _t({AppLang.en: 'On the card', AppLang.zh: '卡上印的密码', AppLang.ja: 'カード記載の番号', AppLang.ko: '카드에 적힌 번호', AppLang.th: 'ที่พิมพ์บนบัตร', AppLang.vi: 'In trên thẻ'});
  String get cwPasswordNote => _t({AppLang.en: 'Please enter the Password on the card to write.', AppLang.zh: '注意：请输入卡上的 Password 进行写卡操作', AppLang.ja: 'カードに記載のパスワードを入力して書き込みます。', AppLang.ko: '카드에 적힌 Password 를 입력하여 카드 쓰기를 진행하세요.', AppLang.th: 'กรุณากรอก Password บนบัตรเพื่อดำเนินการเขียนบัตร', AppLang.vi: 'Vui lòng nhập Password trên thẻ để ghi thẻ.'});
  String get cwPasswordSaved => _t({AppLang.en: 'Using saved card password', AppLang.zh: '使用已保存的卡密码', AppLang.ja: '保存済みのパスワードを使用', AppLang.ko: '저장된 카드 비밀번호 사용', AppLang.th: 'ใช้รหัสผ่านที่บันทึกไว้', AppLang.vi: 'Dùng mật khẩu đã lưu'});
  String get cwEid => _t({AppLang.en: 'EID', AppLang.zh: 'EID', AppLang.ja: 'EID', AppLang.ko: 'EID', AppLang.th: 'EID', AppLang.vi: 'EID'});
  String get cwProfileCount => _t({AppLang.en: 'Cards', AppLang.zh: '卡号数量', AppLang.ja: 'カード数', AppLang.ko: '카드 수', AppLang.th: 'จำนวนการ์ด', AppLang.vi: 'Số thẻ'});
  String get cwStepActivation => _t({AppLang.en: 'Activation code', AppLang.zh: '激活码', AppLang.ja: 'アクティベーションコード', AppLang.ko: '활성화 코드', AppLang.th: 'รหัสเปิดใช้งาน', AppLang.vi: 'Mã kích hoạt'});
  String get cwActivationHint => _t({AppLang.en: 'Paste or scan; the QR code is on the card from your supplier', AppLang.zh: '粘贴或扫码；二维码印在供应商给的卡上', AppLang.ja: '貼り付けまたはスキャン。QRコードはサプライヤーのカードに印刷されています', AppLang.ko: '붙여넣거나 스캔하세요. QR 코드는 공급업체 카드에 인쇄되어 있습니다', AppLang.th: 'วางหรือสแกน QR อยู่บนการ์ดจากผู้จำหน่าย', AppLang.vi: 'Dán hoặc quét; mã QR in trên thẻ từ nhà cung cấp'});
  String get cwActivationPlaceholder => _t({AppLang.en: 'LPA: activation code', AppLang.zh: 'LPA:激活码', AppLang.ja: 'LPA: コード', AppLang.ko: 'LPA: 코드', AppLang.th: 'LPA: รหัส', AppLang.vi: 'LPA: mã'});
  String get cwScanQr => _t({AppLang.en: 'Scan', AppLang.zh: '扫码', AppLang.ja: 'スキャン', AppLang.ko: '스캔', AppLang.th: 'สแกน', AppLang.vi: 'Quét'});
  String get cwConfirmCodeOptional => _t({AppLang.en: 'Confirmation code (optional)', AppLang.zh: '确认码（可选）', AppLang.ja: '確認コード（任意）', AppLang.ko: '확인 코드 (선택)', AppLang.th: 'รหัสยืนยัน (ไม่บังคับ)', AppLang.vi: 'Mã xác nhận (không bắt buộc)'});
  String get cwStepWrite => _t({AppLang.en: 'Write', AppLang.zh: '写卡', AppLang.ja: '書き込み', AppLang.ko: '쓰기', AppLang.th: 'เขียน', AppLang.vi: 'Ghi'});
  String get cwWriteReady => _t({AppLang.en: 'Runs the full SGP.22 download', AppLang.zh: '已连接读卡器', AppLang.ja: 'SGP.22 の全ダウンロードを実行します', AppLang.ko: 'SGP.22 전체 다운로드를 실행합니다', AppLang.th: 'ดำเนินการดาวน์โหลด SGP.22 ทั้งหมด', AppLang.vi: 'Chạy toàn bộ quy trình tải SGP.22'});
  String get cwWriteNeedsReader => _t({AppLang.en: 'Connect a reader in step 1 first', AppLang.zh: '先在第 1 步连上读卡器', AppLang.ja: '先にステップ1でリーダーに接続してください', AppLang.ko: '먼저 1단계에서 리더를 연결하세요', AppLang.th: 'เชื่อมต่อเครื่องอ่านในขั้นตอนที่ 1 ก่อน', AppLang.vi: 'Kết nối đầu đọc ở bước 1 trước'});
  String get cwStartWrite => _t({AppLang.en: 'Start writing', AppLang.zh: '开始写卡', AppLang.ja: '書き込み開始', AppLang.ko: '쓰기 시작', AppLang.th: 'เริ่มเขียน', AppLang.vi: 'Bắt đầu ghi'});
  String get cwRunning => _t({AppLang.en: 'Running…', AppLang.zh: '执行中…', AppLang.ja: '実行中…', AppLang.ko: '실행 중…', AppLang.th: 'กำลังทำงาน…', AppLang.vi: 'Đang chạy…'});
  String get cwMore => _t({AppLang.en: 'More', AppLang.zh: '更多功能', AppLang.ja: 'その他', AppLang.ko: '더 보기', AppLang.th: 'เพิ่มเติม', AppLang.vi: 'Thêm'});
  String get cwCardMgmt => _t({AppLang.en: 'Card management', AppLang.zh: '卡号管理', AppLang.ja: 'カード管理', AppLang.ko: '카드 관리', AppLang.th: 'จัดการการ์ด', AppLang.vi: 'Quản lý thẻ'});
  String get cwNeedConnect => _t({AppLang.en: 'Connect a reader first', AppLang.zh: '需先连接读卡器', AppLang.ja: '先にリーダーに接続', AppLang.ko: '먼저 리더를 연결하세요', AppLang.th: 'เชื่อมต่อเครื่องอ่านก่อน', AppLang.vi: 'Kết nối đầu đọc trước'});
  String get cwNoProfiles => _t({AppLang.en: 'No cards', AppLang.zh: '暂无套餐', AppLang.ja: 'カードなし', AppLang.ko: '카드 없음', AppLang.th: 'ไม่มีการ์ด', AppLang.vi: 'Chưa có thẻ'});
  String get cwEnabled => _t({AppLang.en: 'Enabled', AppLang.zh: '已启用', AppLang.ja: '有効', AppLang.ko: '사용 중', AppLang.th: 'เปิดใช้', AppLang.vi: 'Đã bật'});
  String get cwDisabled => _t({AppLang.en: 'Disabled', AppLang.zh: '未启用', AppLang.ja: '無効', AppLang.ko: '사용 안 함', AppLang.th: 'ปิดใช้', AppLang.vi: 'Đã tắt'});
  String get cwEnable => _t({AppLang.en: 'Enable', AppLang.zh: '启用', AppLang.ja: '有効化', AppLang.ko: '사용', AppLang.th: 'เปิดใช้', AppLang.vi: 'Bật'});
  String get cwDisable => _t({AppLang.en: 'Disable', AppLang.zh: '停用', AppLang.ja: '無効化', AppLang.ko: '중지', AppLang.th: 'ปิดใช้', AppLang.vi: 'Tắt'});
  String get cwRename => _t({AppLang.en: 'Rename', AppLang.zh: '改名', AppLang.ja: '名前変更', AppLang.ko: '이름 변경', AppLang.th: 'เปลี่ยนชื่อ', AppLang.vi: 'Đổi tên'});
  String get cwDelete => _t({AppLang.en: 'Delete', AppLang.zh: '删除', AppLang.ja: '削除', AppLang.ko: '삭제', AppLang.th: 'ลบ', AppLang.vi: 'Xóa'});
  String get cwRenameTitle => _t({AppLang.en: 'Rename card', AppLang.zh: '修改套餐名称', AppLang.ja: 'カード名を変更', AppLang.ko: '카드 이름 변경', AppLang.th: 'เปลี่ยนชื่อการ์ด', AppLang.vi: 'Đổi tên thẻ'});
  String get cwNewName => _t({AppLang.en: 'New name', AppLang.zh: '新名称', AppLang.ja: '新しい名前', AppLang.ko: '새 이름', AppLang.th: 'ชื่อใหม่', AppLang.vi: 'Tên mới'});
  String get cwSave => _t({AppLang.en: 'Save', AppLang.zh: '保存', AppLang.ja: '保存', AppLang.ko: '저장', AppLang.th: 'บันทึก', AppLang.vi: 'Lưu'});
  String get cwCancel => _t({AppLang.en: 'Cancel', AppLang.zh: '取消', AppLang.ja: 'キャンセル', AppLang.ko: '취소', AppLang.th: 'ยกเลิก', AppLang.vi: 'Hủy'});
  String get cwRefresh => _t({AppLang.en: 'Refresh', AppLang.zh: '刷新', AppLang.ja: '更新', AppLang.ko: '새로고침', AppLang.th: 'รีเฟรช', AppLang.vi: 'Làm mới'});
  String get cwCopy => _t({AppLang.en: 'Copy', AppLang.zh: '复制', AppLang.ja: 'コピー', AppLang.ko: '복사', AppLang.th: 'คัดลอก', AppLang.vi: 'Sao chép'});
  String get cwCopied => _t({AppLang.en: 'Copied', AppLang.zh: '已复制，贴给客服即可', AppLang.ja: 'コピーしました。サポートにお送りください', AppLang.ko: '복사됨. 지원팀에 전달하세요', AppLang.th: 'คัดลอกแล้ว ส่งให้ฝ่ายสนับสนุน', AppLang.vi: 'Đã sao chép, gửi cho hỗ trợ'});
  String get cwBluetoothOff => _t({AppLang.en: 'Bluetooth is off. Turn it on first.', AppLang.zh: '蓝牙未开启，请先打开蓝牙', AppLang.ja: 'Bluetoothがオフです。先にオンにしてください', AppLang.ko: '블루투스가 꺼져 있습니다. 먼저 켜세요', AppLang.th: 'บลูทูธปิดอยู่ เปิดก่อน', AppLang.vi: 'Bluetooth đang tắt. Hãy bật trước.'});
  String get cwScanQrTitle => _t({AppLang.en: 'Scan activation QR', AppLang.zh: '扫描激活码二维码', AppLang.ja: 'アクティベーションQRをスキャン', AppLang.ko: '활성화 QR 스캔', AppLang.th: 'สแกน QR เปิดใช้งาน', AppLang.vi: 'Quét QR kích hoạt'});
  String get cwConfirmCarrier => _t({AppLang.en: 'Confirm carrier', AppLang.zh: '确认运营商', AppLang.ja: '通信事業者の確認', AppLang.ko: '통신사 확인', AppLang.th: 'ยืนยันผู้ให้บริการ', AppLang.vi: 'Xác nhận nhà mạng'});
  String get cwCarrierUnknown => _t({AppLang.en: '(carrier name not provided)', AppLang.zh: '（运营商未提供名称）', AppLang.ja: '（事業者名の提供なし）', AppLang.ko: '(통신사 이름 없음)', AppLang.th: '(ไม่มีชื่อผู้ให้บริการ)', AppLang.vi: '(nhà mạng không cung cấp tên)'});
  String get cwWritingProgress => _t({AppLang.en: 'Downloading and installing (takes minutes, do not leave)…', AppLang.zh: '正在下载并安装（几分钟，请勿离开）…', AppLang.ja: 'ダウンロードとインストール中（数分かかります。離れないでください）…', AppLang.ko: '다운로드 및 설치 중 (몇 분 소요, 나가지 마세요)…', AppLang.th: 'กำลังดาวน์โหลดและติดตั้ง (ใช้เวลาหลายนาที อย่าออก)', AppLang.vi: 'Đang tải và cài đặt (mất vài phút, đừng rời đi)…'});
  String get cwWriteDone => _t({AppLang.en: 'Write complete', AppLang.zh: '写入完成', AppLang.ja: '書き込み完了', AppLang.ko: '쓰기 완료', AppLang.th: 'เขียนเสร็จ', AppLang.vi: 'Ghi hoàn tất'});
  String get cwWriteFailed => _t({AppLang.en: 'Write failed', AppLang.zh: '写卡失败', AppLang.ja: '書き込み失敗', AppLang.ko: '쓰기 실패', AppLang.th: 'เขียนล้มเหลว', AppLang.vi: 'Ghi thất bại'});
  String get cwReadFailed => _t({AppLang.en: 'Read failed', AppLang.zh: '读取失败', AppLang.ja: '読み取り失敗', AppLang.ko: '읽기 실패', AppLang.th: 'อ่านล้มเหลว', AppLang.vi: 'Đọc thất bại'});
  String get cwConnectFailed => _t({AppLang.en: 'Connect failed', AppLang.zh: '连接失败', AppLang.ja: '接続失敗', AppLang.ko: '연결 실패', AppLang.th: 'เชื่อมต่อล้มเหลว', AppLang.vi: 'Kết nối thất bại'});
  String get cwOk => _t({AppLang.en: 'OK', AppLang.zh: '确定', AppLang.ja: 'OK', AppLang.ko: '확인', AppLang.th: 'ตกลง', AppLang.vi: 'OK'});
  String get cwClose => _t({AppLang.en: 'Close', AppLang.zh: '关闭', AppLang.ja: '閉じる', AppLang.ko: '닫기', AppLang.th: 'ปิด', AppLang.vi: 'Đóng'});
  String get cwActivationInvalid => _t({AppLang.en: 'Invalid activation code, expected LPA:1\$host\$matching-id', AppLang.zh: '激活码格式不正确，应形如 LPA:1\$主机\$匹配码', AppLang.ja: 'コードが正しくありません。LPA:1\$ホスト\$照合ID の形式です', AppLang.ko: '활성화 코드가 잘못되었습니다. LPA:1\$호스트\$매칭ID 형식입니다', AppLang.th: 'รหัสไม่ถูกต้อง รูปแบบ LPA:1\$โฮสต์\$รหัสจับคู่', AppLang.vi: 'Mã kích hoạt không hợp lệ, dạng LPA:1\$host\$mã-khớp'});
  String get cwDeleteConfirm => _t({AppLang.en: 'Delete this card? This cannot be undone.', AppLang.zh: '确定删除该卡号？此操作不可撤销。', AppLang.ja: 'このカードを削除しますか？元に戻せません。', AppLang.ko: '이 카드를 삭제할까요? 되돌릴 수 없습니다.', AppLang.th: 'ลบการ์ดนี้หรือไม่? ไม่สามารถย้อนกลับได้', AppLang.vi: 'Xóa thẻ này? Không thể hoàn tác.'});
  String get cwEnabledSuffix => _t({AppLang.en: ' (one enabled)', AppLang.zh: '（有启用中的）', AppLang.ja: '（有効なものあり）', AppLang.ko: ' (사용 중 있음)', AppLang.th: ' (มีที่เปิดใช้)', AppLang.vi: ' (có thẻ đang bật)'});
  String get cwNoCardInfo => _t({AppLang.en: 'No card info (vendor SDK only)', AppLang.zh: '暂无卡片信息（需厂商 SDK 连接）', AppLang.ja: 'カード情報なし（ベンダーSDK接続が必要）', AppLang.ko: '카드 정보 없음 (벤더 SDK 연결 필요)', AppLang.th: 'ไม่มีข้อมูลการ์ด (ต้องเชื่อมต่อ SDK ผู้ผลิต)', AppLang.vi: 'Không có thông tin thẻ (cần SDK nhà sản xuất)'});


  // ------------------------------------------------- card writer: runtime status
  // These carry values (ICCID, result codes), so they are methods rather than
  // plain getters. Placeholders are kept as {0}/{1} so translators never have
  // to reason about Dart interpolation.
  String cwStatusConnectSdk() => _t({AppLang.en: 'Connecting to reader (vendor SDK)…', AppLang.zh: '正在连接读卡器（厂商 SDK）…', AppLang.ja: 'リーダーに接続中（ベンダーSDK）…', AppLang.ko: '리더 연결 중 (벤더 SDK)…', AppLang.th: 'กำลังเชื่อมต่อเครื่องอ่าน (SDK ผู้ผลิต)…', AppLang.vi: 'Đang kết nối đầu đọc (SDK nhà sản xuất)…'});
  String cwStatusConnectVendor() => _t({AppLang.en: 'Connecting (vendor SDK)…', AppLang.zh: '正在连接（厂商 SDK）…', AppLang.ja: '接続中（ベンダーSDK）…', AppLang.ko: '연결 중 (벤더 SDK)…', AppLang.th: 'กำลังเชื่อมต่อ (SDK ผู้ผลิต)…', AppLang.vi: 'Đang kết nối (SDK nhà sản xuất)…'});
  String cwStatusBleSession() => _t({AppLang.en: 'Opening BLE session…', AppLang.zh: '正在建立 BLE 会话…', AppLang.ja: 'BLEセッションを開いています…', AppLang.ko: 'BLE 세션 여는 중…', AppLang.th: 'กำลังเปิดเซสชัน BLE…', AppLang.vi: 'Đang mở phiên BLE…'});
  String cwStatusReadingCard() => _t({AppLang.en: 'Reading card information…', AppLang.zh: '正在读取卡片信息…', AppLang.ja: 'カード情報を読み取り中…', AppLang.ko: '카드 정보 읽는 중…', AppLang.th: 'กำลังอ่านข้อมูลการ์ด…', AppLang.vi: 'Đang đọc thông tin thẻ…'});
  String cwStatusConfirmCarrier() => _t({AppLang.en: 'Checking the carrier…', AppLang.zh: '正在确认运营商…', AppLang.ja: '通信事業者を確認中…', AppLang.ko: '통신사 확인 중…', AppLang.th: 'กำลังตรวจสอบผู้ให้บริการ…', AppLang.vi: 'Đang kiểm tra nhà mạng…'});
  String cwStatusPrepareDownload() => _t({AppLang.en: 'Preparing download…', AppLang.zh: '准备下载…', AppLang.ja: 'ダウンロード準備中…', AppLang.ko: '다운로드 준비 중…', AppLang.th: 'กำลังเตรียมดาวน์โหลด…', AppLang.vi: 'Đang chuẩn bị tải…'});
  String cwStatusRenotify() => _t({AppLang.en: 'Re-registering the device on the network…', AppLang.zh: '正在让设备重新询卡注网…', AppLang.ja: 'デバイスを再登録しています…', AppLang.ko: '기기를 네트워크에 다시 등록 중…', AppLang.th: 'กำลังลงทะเบียนอุปกรณ์ใหม่บนเครือข่าย…', AppLang.vi: 'Đang đăng ký lại thiết bị với mạng…'});
  String get cwStatusReadCardInfo => _t({AppLang.en: 'Read card information', AppLang.zh: '读取卡信息', AppLang.ja: 'カード情報を読む', AppLang.ko: '카드 정보 읽기', AppLang.th: 'อ่านข้อมูลการ์ด', AppLang.vi: 'Đọc thông tin thẻ'});
  String cwStatusSyncNotif() => _t({AppLang.en: 'Syncing notifications…', AppLang.zh: '同步通知…', AppLang.ja: '通知を同期中…', AppLang.ko: '알림 동기화 중…', AppLang.th: 'กำลังซิงค์การแจ้งเตือน…', AppLang.vi: 'Đang đồng bộ thông báo…'});
  String get cwStatusRenotifyShort => _t({AppLang.en: 'Re-register', AppLang.zh: '重新注网', AppLang.ja: '再登録', AppLang.ko: '재등록', AppLang.th: 'ลงทะเบียนใหม่', AppLang.vi: 'Đăng ký lại'});
  String cwStatusSync() => _t({AppLang.en: 'Sync', AppLang.zh: '同步', AppLang.ja: '同期', AppLang.ko: '동기화', AppLang.th: 'ซิงค์', AppLang.vi: 'Đồng bộ'});
  String cwStatusRefreshingProfiles() => _t({AppLang.en: 'Refresh cards', AppLang.zh: '刷新套餐', AppLang.ja: 'カードを更新', AppLang.ko: '카드 새로고침', AppLang.th: 'รีเฟรชการ์ด', AppLang.vi: 'Làm mới thẻ'});
  String cwSdkConnected() => _t({AppLang.en: 'Vendor SDK connected', AppLang.zh: '厂商 SDK 已连接', AppLang.ja: 'ベンダーSDK接続済み', AppLang.ko: '벤더 SDK 연결됨', AppLang.th: 'เชื่อมต่อ SDK ผู้ผลิตแล้ว', AppLang.vi: 'Đã kết nối SDK nhà sản xuất'});
  String cwWriteAutoEnable() => _t({AppLang.en: 'The card will be enabled automatically after writing.', AppLang.zh: '写入后会自动启用该套餐。', AppLang.ja: '書き込み後に自動で有効化されます。', AppLang.ko: '쓰기 후 자동으로 활성화됩니다.', AppLang.th: 'การ์ดจะถูกเปิดใช้โดยอัตโนมัติหลังเขียน', AppLang.vi: 'Thẻ sẽ tự động được bật sau khi ghi.'});
  String cwWriteStartShort() => _t({AppLang.en: 'Write', AppLang.zh: '开始写入', AppLang.ja: '書き込み開始', AppLang.ko: '쓰기 시작', AppLang.th: 'เริ่มเขียน', AppLang.vi: 'Bắt đầu ghi'});
  String cwCardCount(int n) => _t({AppLang.en: '$n cards', AppLang.zh: '$n 个', AppLang.ja: '$n 件', AppLang.ko: '$n개', AppLang.th: '$n รายการ', AppLang.vi: '$n thẻ'});
  String cwCardCountEnabled(int n) => _t({AppLang.en: '$n cards (one enabled)', AppLang.zh: '$n 个（有启用中的）', AppLang.ja: '$n 件（有効なものあり）', AppLang.ko: '$n개 (사용 중 있음)', AppLang.th: '$n รายการ (มีที่เปิดใช้)', AppLang.vi: '$n thẻ (có thẻ đang bật)'});
  String cwWriteDoneIccid(String iccid) => _t({AppLang.en: 'Write complete, ICCID $iccid', AppLang.zh: '写入完成，ICCID $iccid', AppLang.ja: '書き込み完了 ICCID $iccid', AppLang.ko: '쓰기 완료, ICCID $iccid', AppLang.th: 'เขียนเสร็จ ICCID $iccid', AppLang.vi: 'Ghi hoàn tất, ICCID $iccid'});
  String cwOpFailed(String label, String reason) => _t({AppLang.en: '$label failed: $reason', AppLang.zh: '$label 失败：$reason', AppLang.ja: '$label 失敗：$reason', AppLang.ko: '$label 실패: $reason', AppLang.th: '$label ล้มเหลว: $reason', AppLang.vi: '$label thất bại: $reason'});
  String cwOpSucceeded(String label, String iccid) => _t({AppLang.en: '$label succeeded: $iccid', AppLang.zh: '$label 成功：$iccid', AppLang.ja: '$label 成功：$iccid', AppLang.ko: '$label 성공: $iccid', AppLang.th: '$label สำเร็จ: $iccid', AppLang.vi: '$label thành công: $iccid'});
  String cwOpResultCode(String label, int code) => _t({AppLang.en: '$label failed: result code $code', AppLang.zh: '$label 失败：结果码 $code', AppLang.ja: '$label 失敗：結果コード $code', AppLang.ko: '$label 실패: 결과 코드 $code', AppLang.th: '$label ล้มเหลว: รหัสผลลัพธ์ $code', AppLang.vi: '$label thất bại: mã kết quả $code'});
  String cwOpNotConnected(String label) => _t({AppLang.en: '$label failed: not connected', AppLang.zh: '$label 失败：未连接', AppLang.ja: '$label 失敗：未接続', AppLang.ko: '$label 실패: 연결 안 됨', AppLang.th: '$label ล้มเหลว: ยังไม่เชื่อมต่อ', AppLang.vi: '$label thất bại: chưa kết nối'});
  String cwRefreshFailed(String what, String error) => _t({AppLang.en: 'Could not refresh $what: $error', AppLang.zh: '刷新$what失败：$error', AppLang.ja: '$what の更新に失敗：$error', AppLang.ko: '$what 새로고침 실패: $error', AppLang.th: 'รีเฟรช $what ไม่สำเร็จ: $error', AppLang.vi: 'Không làm mới được $what: $error'});
  String cwReadFailedWith(String error) => _t({AppLang.en: 'Read failed: $error', AppLang.zh: '读取卡片信息失败：$error', AppLang.ja: '読み取り失敗：$error', AppLang.ko: '읽기 실패: $error', AppLang.th: 'อ่านล้มเหลว: $error', AppLang.vi: 'Đọc thất bại: $error'});
  String cwScanFailed(String error) => _t({AppLang.en: 'Scan failed: $error', AppLang.zh: '扫描失败：$error', AppLang.ja: 'スキャン失敗：$error', AppLang.ko: '스캔 실패: $error', AppLang.th: 'สแกนล้มเหลว: $error', AppLang.vi: 'Quét thất bại: $error'});
  String cwConnectFailedWith(String error) => _t({AppLang.en: 'Connect failed: $error', AppLang.zh: '连接失败：$error', AppLang.ja: '接続失敗：$error', AppLang.ko: '연결 실패: $error', AppLang.th: 'เชื่อมต่อล้มเหลว: $error', AppLang.vi: 'Kết nối thất bại: $error'});
  String cwWriteFailedWith(String error) => _t({AppLang.en: 'Write failed: $error', AppLang.zh: '写卡失败：$error', AppLang.ja: '書き込み失敗：$error', AppLang.ko: '쓰기 실패: $error', AppLang.th: 'เขียนล้มเหลว: $error', AppLang.vi: 'Ghi thất bại: $error'});
  String cwDeleteConfirmIccid(String iccid) => _t({AppLang.en: 'Delete $iccid? This cannot be undone.', AppLang.zh: '确定删除 $iccid？此操作不可撤销。', AppLang.ja: '$iccid を削除しますか？元に戻せません。', AppLang.ko: '$iccid 를 삭제할까요? 되돌릴 수 없습니다.', AppLang.th: 'ลบ $iccid? ไม่สามารถย้อนกลับได้', AppLang.vi: 'Xóa $iccid? Không thể hoàn tác.'});
  String cwPasswordPrompt(String reader) => _t({AppLang.en: 'Reader $reader needs a password to open the secure channel.', AppLang.zh: '读卡器 $reader 需要密码才能建立安全通道。', AppLang.ja: 'リーダー $reader は安全な通信路の確立にパスワードが必要です。', AppLang.ko: '리더 $reader 는 보안 채널을 열려면 비밀번호가 필요합니다.', AppLang.th: 'เครื่องอ่าน $reader ต้องใช้รหัสผ่านเพื่อเปิดช่องทางที่ปลอดภัย', AppLang.vi: 'Đầu đọc $reader cần mật khẩu để mở kênh bảo mật.'});
  String cwNotifPending(int n) => _t({AppLang.en: '$n notifications pending', AppLang.zh: '待发通知 $n 条', AppLang.ja: '未送信の通知 $n 件', AppLang.ko: '대기 중인 알림 $n건', AppLang.th: 'การแจ้งเตือนค้าง $n รายการ', AppLang.vi: '$n thông báo đang chờ'});
  String cwNotifDelivered(int n) => _t({AppLang.en: 'Notifications: $n delivered', AppLang.zh: '通知同步：送达 $n 条', AppLang.ja: '通知同期：$n 件送信', AppLang.ko: '알림 동기화: $n건 전달', AppLang.th: 'ซิงค์การแจ้งเตือน: ส่งแล้ว $n รายการ', AppLang.vi: 'Đồng bộ thông báo: đã gửi $n'});
  String cwNotifSyncFailed(String error) => _t({AppLang.en: 'Notification sync failed: $error', AppLang.zh: '通知同步失败：$error', AppLang.ja: '通知同期に失敗：$error', AppLang.ko: '알림 동기화 실패: $error', AppLang.th: 'ซิงค์การแจ้งเตือนล้มเหลว: $error', AppLang.vi: 'Đồng bộ thông báo thất bại: $error'});
  String cwRenoitfyFailed(String error) => _t({AppLang.en: 'Written, but the device could not re-register ($error). Try restarting the reader.', AppLang.zh: '写入成功，但设备重新注网失败（$error），可能需要重启读卡器', AppLang.ja: '書き込み成功。ただし再登録に失敗しました（$error）。リーダーの再起動をお試しください。', AppLang.ko: '쓰기 성공. 다만 재등록에 실패했습니다 ($error). 리더를 재시작해 보세요.', AppLang.th: 'เขียนสำเร็จ แต่ลงทะเบียนใหม่ไม่สำเร็จ ($error) ลองรีสตาร์ทเครื่องอ่าน', AppLang.vi: 'Đã ghi, nhưng thiết bị không đăng ký lại được ($error). Thử khởi động lại đầu đọc.'});
  String cwWriteCancelled() => _t({AppLang.en: 'Write cancelled', AppLang.zh: '已取消写入', AppLang.ja: '書き込みを中止しました', AppLang.ko: '쓰기 취소됨', AppLang.th: 'ยกเลิกการเขียน', AppLang.vi: 'Đã hủy ghi'});
  String cwFailCount(int n) => _t({AppLang.en: ', $n failed', AppLang.zh: '，失败 $n 条', AppLang.ja: '、$n 件失敗', AppLang.ko: ', $n건 실패', AppLang.th: ', ล้มเหลว $n', AppLang.vi: ', $n thất bại'});
  String get cwCopyError => _t({AppLang.en: 'Copy error details', AppLang.zh: '复制错误信息', AppLang.ja: 'エラー詳細をコピー', AppLang.ko: '오류 정보 복사', AppLang.th: 'คัดลอกรายละเอียดข้อผิดพลาด', AppLang.vi: 'Sao chép chi tiết lỗi'});
  String get cwCopiedForSupport => _t({AppLang.en: 'Copied — paste it to support', AppLang.zh: '已复制，贴给我即可', AppLang.ja: 'コピーしました。サポートにお送りください', AppLang.ko: '복사됨 — 지원팀에 붙여넣으세요', AppLang.th: 'คัดลอกแล้ว ส่งให้ฝ่ายสนับสนุน', AppLang.vi: 'Đã sao chép — dán cho hỗ trợ'});
  String get cwError => _t({AppLang.en: 'Error', AppLang.zh: '错误', AppLang.ja: 'エラー', AppLang.ko: '오류', AppLang.th: 'ข้อผิดพลาด', AppLang.vi: 'Lỗi'});
  String get cwFailed => _t({AppLang.en: 'Failed', AppLang.zh: '失败', AppLang.ja: '失敗', AppLang.ko: '실패', AppLang.th: 'ล้มเหลว', AppLang.vi: 'Thất bại'});
  String get cwLast40Lines => _t({AppLang.en: 'Last 40 lines', AppLang.zh: '最近 40 行', AppLang.ja: '直近40行', AppLang.ko: '최근 40줄', AppLang.th: '40 บรรทัดล่าสุด', AppLang.vi: '40 dòng gần nhất'});


  // ------------------------------------------------------ activate: card writer
  String get btWrite => _t({AppLang.en: 'Bluetooth card writer', AppLang.zh: '蓝牙写卡', AppLang.ja: 'Bluetoothカード書き込み', AppLang.ko: '블루투스 카드 쓰기', AppLang.th: 'เขียนการ์ดผ่านบลูทูธ', AppLang.vi: 'Ghi thẻ qua Bluetooth'});
  String get btWriteDesc => _t({AppLang.en: 'Connect a Bluetooth eSIM card and install a plan onto it', AppLang.zh: '连接蓝牙 eSIM 卡，把套餐写入实体卡', AppLang.ja: 'Bluetooth eSIMカードに接続し、プランを書き込みます', AppLang.ko: '블루투스 eSIM 카드에 연결해 요금제를 기록합니다', AppLang.th: 'เชื่อมต่อการ์ด eSIM บลูทูธแล้วเขียนแพ็กเกจลงการ์ด', AppLang.vi: 'Kết nối thẻ eSIM Bluetooth và ghi gói vào thẻ'});
  String iccidDetected(String v) => _t({AppLang.en: 'ICCID detected and filled in: $v', AppLang.zh: '已识别并填入 ICCID：$v', AppLang.ja: 'ICCID を認識しました：$v', AppLang.ko: 'ICCID 인식됨: $v', AppLang.th: 'ตรวจพบ ICCID และกรอกแล้ว: $v', AppLang.vi: 'Đã nhận ICCID và điền: $v'});
  String cameraOpenFailed(String e) => _t({AppLang.en: 'Could not open the camera: $e\nType the ICCID manually, or allow camera access in system settings.', AppLang.zh: '无法打开相机：$e\n可手动输入 ICCID，或在系统设置里允许相机权限。', AppLang.ja: 'カメラを開けません：$e\nICCID を手入力するか、システム設定でカメラ権限を許可してください。', AppLang.ko: '카메라를 열 수 없습니다: $e\nICCID를 직접 입력하거나 시스템 설정에서 카메라 권한을 허용하세요.', AppLang.th: 'เปิดกล้องไม่ได้: $e\nพิมพ์ ICCID เอง หรืออนุญาตสิทธิ์กล้องในตั้งค่าระบบ', AppLang.vi: 'Không mở được camera: $e\nNhập ICCID thủ công hoặc cấp quyền camera trong cài đặt hệ thống.'});


  String cwStatusCheckQuota() => _t({AppLang.en: 'Checking the card quota…', AppLang.zh: '正在校验写卡配额…', AppLang.ja: 'クォータを確認中…', AppLang.ko: '할당량 확인 중…', AppLang.th: 'กำลังตรวจสอบโควตา…', AppLang.vi: 'Đang kiểm tra hạn mức…'});
  String cwQuotaLine(int used, int cap) => _t({AppLang.en: 'Card quota: $used / $cap used', AppLang.zh: '写卡配额：已用 $used / 上限 $cap', AppLang.ja: 'クォータ：$used / $cap 使用済み', AppLang.ko: '할당량: $used / $cap 사용', AppLang.th: 'โควตา: ใช้ $used / $cap', AppLang.vi: 'Hạn mức: đã dùng $used / $cap'});
  String cwQuotaCheckFailed(String e) => _t({AppLang.en: 'Quota could not be verified ($e); continuing without the server check.', AppLang.zh: '配额校验失败（$e），本次未做服务器校验', AppLang.ja: 'クォータを確認できません（$e）。サーバー確認なしで続行します。', AppLang.ko: '할당량을 확인하지 못했습니다($e). 서버 확인 없이 진행합니다.', AppLang.th: 'ตรวจสอบโควตาไม่สำเร็จ ($e) ดำเนินการต่อโดยไม่ตรวจกับเซิร์ฟเวอร์', AppLang.vi: 'Không xác minh được hạn mức ($e); tiếp tục mà không kiểm tra với máy chủ.'});
  String get cwQuotaTitle => _t({AppLang.en: 'Quota', AppLang.zh: '配额', AppLang.ja: 'クォータ', AppLang.ko: '할당량', AppLang.th: 'โควตา', AppLang.vi: 'Hạn mức'});

  // order status labels
  String statusLabel(String s) {
    switch (s) {
      case 'active':
      case 'fulfilled':
        return _t({AppLang.en: 'Active', AppLang.zh: '使用中', AppLang.ja: '有効', AppLang.ko: '활성', AppLang.th: 'ใช้งาน', AppLang.vi: 'Đang dùng'});
      case 'issued':
        return _t({AppLang.en: 'Pending', AppLang.zh: '待激活', AppLang.ja: '保留中', AppLang.ko: '대기', AppLang.th: 'รอเปิดใช้', AppLang.vi: 'Chờ kích hoạt'});
      case 'paid':
        return _t({AppLang.en: 'Paid', AppLang.zh: '已支付', AppLang.ja: '支払済', AppLang.ko: '결제됨', AppLang.th: 'ชำระแล้ว', AppLang.vi: 'Đã thanh toán'});
      case 'pending':
        return _t({AppLang.en: 'Pending', AppLang.zh: '待支付', AppLang.ja: '保留中', AppLang.ko: '대기', AppLang.th: 'รอดำเนินการ', AppLang.vi: 'Chờ thanh toán'});
      case 'cancelled':
        return _t({AppLang.en: 'Cancelled', AppLang.zh: '已取消', AppLang.ja: 'キャンセル', AppLang.ko: '취소됨', AppLang.th: 'ยกเลิก', AppLang.vi: 'Đã hủy'});
      case 'refunded':
        return _t({AppLang.en: 'Refunded', AppLang.zh: '已退款', AppLang.ja: '返金済', AppLang.ko: '환불됨', AppLang.th: 'คืนเงิน', AppLang.vi: 'Đã hoàn tiền'});
      case 'expired':
        return _t({AppLang.en: 'Expired', AppLang.zh: '已过期', AppLang.ja: '期限切れ', AppLang.ko: '만료', AppLang.th: 'หมดอายุ', AppLang.vi: 'Hết hạn'});
      default:
        return s;
    }
  }


  // ---- card info page ----
  String get cardDetails => _t({AppLang.en: 'Card Details', AppLang.zh: '卡片详情', AppLang.ja: 'カード詳細', AppLang.ko: '카드 세부정보', AppLang.th: 'รายละเอียดบัตร', AppLang.vi: 'Chi tiết thẻ'});
  String get cardStatus => _t({AppLang.en: 'Card Status', AppLang.zh: '卡状态', AppLang.ja: 'カード状態', AppLang.ko: '카드 상태', AppLang.th: 'สถานะบัตร', AppLang.vi: 'Trạng thái thẻ'});
  String get statusActive => _t({AppLang.en: 'Active', AppLang.zh: '已激活', AppLang.ja: '有効', AppLang.ko: '활성', AppLang.th: 'ใช้งานได้', AppLang.vi: 'Đã kích hoạt'});
  String get statusPending => _t({AppLang.en: 'Not activated', AppLang.zh: '待激活', AppLang.ja: '未アクティベート', AppLang.ko: '활성화 대기', AppLang.th: 'รอเปิดใช้งาน', AppLang.vi: 'Chưa kích hoạt'});
  String get statusSuspended => _t({AppLang.en: 'Suspended', AppLang.zh: '停机', AppLang.ja: '停止中', AppLang.ko: '정지', AppLang.th: 'ระงับ', AppLang.vi: 'Tạm dừng'});
  String get statusCancelled => _t({AppLang.en: 'Cancelled', AppLang.zh: '已注销', AppLang.ja: '解約済み', AppLang.ko: '해지됨', AppLang.th: 'ยกเลิกแล้ว', AppLang.vi: 'Đã hủy'});
  String get statusExpired => _t({AppLang.en: 'Expired', AppLang.zh: '已过期', AppLang.ja: '期限切れ', AppLang.ko: '만료됨', AppLang.th: 'หมดอายุ', AppLang.vi: 'Đã hết hạn'});
  String get statusUnknown => _t({AppLang.en: 'Unknown', AppLang.zh: '未知', AppLang.ja: '不明', AppLang.ko: '알 수 없음', AppLang.th: 'ไม่ทราบ', AppLang.vi: 'Không rõ'});
  String get remaining => _t({AppLang.en: 'Remaining', AppLang.zh: '剩余', AppLang.ja: '残り', AppLang.ko: '남은 양', AppLang.th: 'คงเหลือ', AppLang.vi: 'Còn lại'});
  String get currentPlan => _t({AppLang.en: 'Current plan', AppLang.zh: '当前套餐', AppLang.ja: '現在のプラン', AppLang.ko: '현재 요금제', AppLang.th: 'แพ็กเกจปัจจุบัน', AppLang.vi: 'Gói hiện tại'});
  String get rechargePlans => _t({AppLang.en: 'Recharge plans', AppLang.zh: '可充值套餐', AppLang.ja: 'チャージ可能なプラン', AppLang.ko: '충전 가능 요금제', AppLang.th: 'แพ็กเกจเติมเงิน', AppLang.vi: 'Gói nạp thêm'});
  String get addOns => _t({AppLang.en: 'Add-ons', AppLang.zh: '叠加包', AppLang.ja: 'アドオン', AppLang.ko: '추가 패키지', AppLang.th: 'แพ็กเกจเสริม', AppLang.vi: 'Gói bổ trợ'});
  String get noPackages => _t({AppLang.en: 'No plans available', AppLang.zh: '暂无套餐', AppLang.ja: 'プランがありません', AppLang.ko: '사용 가능한 요금제 없음', AppLang.th: 'ไม่มีแพ็กเกจ', AppLang.vi: 'Không có gói nào'});
  String get loadPackages => _t({AppLang.en: 'Load plans', AppLang.zh: '加载套餐', AppLang.ja: 'プランを読み込む', AppLang.ko: '요금제 불러오기', AppLang.th: 'โหลดแพ็กเกจ', AppLang.vi: 'Tải gói'});
  String get flow => _t({AppLang.en: 'Data', AppLang.zh: '流量', AppLang.ja: 'データ量', AppLang.ko: '데이터', AppLang.th: 'ข้อมูล', AppLang.vi: 'Dữ liệu'});
  String get price => _t({AppLang.en: 'Price', AppLang.zh: '价格', AppLang.ja: '料金', AppLang.ko: '가격', AppLang.th: 'ราคา', AppLang.vi: 'Giá'});
  String get expiresAt => _t({AppLang.en: 'Expires', AppLang.zh: '到期', AppLang.ja: '有効期限', AppLang.ko: '만료', AppLang.th: 'หมดอายุ', AppLang.vi: 'Hết hạn'});
  String get recharge => _t({AppLang.en: 'Recharge', AppLang.zh: '充值', AppLang.ja: 'チャージ', AppLang.ko: '충전', AppLang.th: 'เติมเงิน', AppLang.vi: 'Nạp tiền'});
  String get confirmRecharge => _t({AppLang.en: 'Confirm recharge', AppLang.zh: '确认充值', AppLang.ja: 'チャージ確認', AppLang.ko: '충전 확인', AppLang.th: 'ยืนยันการเติมเงิน', AppLang.vi: 'Xác nhận nạp tiền'});
  String get rechargeHint => _t({AppLang.en: 'The plan takes effect immediately after recharging.', AppLang.zh: '充值后将立即对该卡生效。', AppLang.ja: 'チャージ後すぐに有効になります。', AppLang.ko: '충전 후 즉시 적용됩니다.', AppLang.th: 'แพ็กเกจจะมีผลทันทีหลังเติมเงิน', AppLang.vi: 'Gói sẽ có hiệu lực ngay sau khi nạp.'});
  String get rechargeSuccess => _t({AppLang.en: 'Recharge successful', AppLang.zh: '充值成功', AppLang.ja: 'チャージ成功', AppLang.ko: '충전 완료', AppLang.th: 'เติมเงินสำเร็จ', AppLang.vi: 'Nạp tiền thành công'});
  String get rechargeFailed => _t({AppLang.en: 'Recharge failed', AppLang.zh: '充值失败', AppLang.ja: 'チャージ失敗', AppLang.ko: '충전 실패', AppLang.th: 'เติมเงินไม่สำเร็จ', AppLang.vi: 'Nạp tiền thất bại'});
  String get queryFailed => _t({AppLang.en: 'Query failed', AppLang.zh: '查询失败', AppLang.ja: '取得に失敗しました', AppLang.ko: '조회 실패', AppLang.th: 'สอบถามไม่สำเร็จ', AppLang.vi: 'Truy vấn thất bại'});
  String get retry => _t({AppLang.en: 'Retry', AppLang.zh: '重试', AppLang.ja: '再試行', AppLang.ko: '재시도', AppLang.th: 'ลองใหม่', AppLang.vi: 'Thử lại'});
  String get cancel => _t({AppLang.en: 'Cancel', AppLang.zh: '取消', AppLang.ja: 'キャンセル', AppLang.ko: '취소', AppLang.th: 'ยกเลิก', AppLang.vi: 'Hủy'});
  String get confirm => _t({AppLang.en: 'Confirm', AppLang.zh: '确认', AppLang.ja: '確認', AppLang.ko: '확인', AppLang.th: 'ยืนยัน', AppLang.vi: 'Xác nhận'});

  // ---- recharge history ----
  String get rechargeRecords => _t({AppLang.en: 'Recharge history', AppLang.zh: '充值记录', AppLang.ja: 'チャージ履歴', AppLang.ko: '충전 내역', AppLang.th: 'ประวัติการเติมเงิน', AppLang.vi: 'Lịch sử nạp tiền'});
  String get noRecharges => _t({AppLang.en: 'No recharge orders', AppLang.zh: '还没有充值记录', AppLang.ja: 'チャージ履歴がありません', AppLang.ko: '충전 내역이 없습니다', AppLang.th: 'ยังไม่มีการเติมเงิน', AppLang.vi: 'Chưa có lịch sử nạp'});
  String get noRechargesHint => _t({AppLang.en: 'Recharge a plan to see it here', AppLang.zh: '充值套餐后会在这里显示', AppLang.ja: 'プランをチャージするとここに表示されます', AppLang.ko: '요금제를 충전하면 여기에 표시됩니다', AppLang.th: 'เติมเงินแพ็กเกจแล้วจะแสดงที่นี่', AppLang.vi: 'Nạp gói sẽ hiển thị ở đây'});
  String get stPendingPay => _t({AppLang.en: 'Awaiting payment', AppLang.zh: '待支付', AppLang.ja: '支払い待ち', AppLang.ko: '결제 대기', AppLang.th: 'รอชำระเงิน', AppLang.vi: 'Chờ thanh toán'});
  String get stPaid => _t({AppLang.en: 'Paid', AppLang.zh: '已支付', AppLang.ja: '支払い済み', AppLang.ko: '결제 완료', AppLang.th: 'ชำระแล้ว', AppLang.vi: 'Đã thanh toán'});
  String get stDone => _t({AppLang.en: 'Recharged', AppLang.zh: '已充值', AppLang.ja: 'チャージ済み', AppLang.ko: '충전 완료', AppLang.th: 'เติมเงินแล้ว', AppLang.vi: 'Đã nạp'});
  String get stFailed => _t({AppLang.en: 'Failed', AppLang.zh: '充值失败', AppLang.ja: 'チャージ失敗', AppLang.ko: '충전 실패', AppLang.th: 'ล้มเหลว', AppLang.vi: 'Thất bại'});
  String get stRefunded => _t({AppLang.en: 'Refunded', AppLang.zh: '已退款', AppLang.ja: '返金済み', AppLang.ko: '환불됨', AppLang.th: 'คืนเงินแล้ว', AppLang.vi: 'Đã hoàn tiền'});
  String get confirmPay => _t({AppLang.en: 'Confirm payment', AppLang.zh: '确认支付', AppLang.ja: '支払い確認', AppLang.ko: '결제 확인', AppLang.th: 'ยืนยันการชำระเงิน', AppLang.vi: 'Xác nhận thanh toán'});

  // ---- my cards (我的卡) ----
  String get viewMyCards => _t({AppLang.en: 'View my cards', AppLang.zh: '查看我的卡', AppLang.ja: 'カードを見る', AppLang.ko: '내 카드 보기', AppLang.th: 'ดูการ์ดของฉัน', AppLang.vi: 'Xem thẻ của tôi'});
  String get cardsEmptyTitle => _t({AppLang.en: 'No cards yet', AppLang.zh: '还没有卡', AppLang.ja: 'カードがありません', AppLang.ko: '아직 카드가 없습니다', AppLang.th: 'ยังไม่มีการ์ด', AppLang.vi: 'Chưa có thẻ'});
  String get cardsEmptyHint => _t({AppLang.en: 'Your cards show up here after purchase', AppLang.zh: '购买套餐后，你的卡会出现在这里', AppLang.ja: '購入したカードはここに表示されます', AppLang.ko: '구매한 카드는 여기에 표시됩니다', AppLang.th: 'การ์ดของคุณจะแสดงที่นี่หลังการซื้อ', AppLang.vi: 'Thẻ sẽ xuất hiện ở đây sau khi mua'});
  String get autoRefreshOn => _t({AppLang.en: 'Auto refresh on', AppLang.zh: '自动刷新：开', AppLang.ja: '自動更新：オン', AppLang.ko: '자동 새로고침 켜짐', AppLang.th: 'เปิดรีเฟรชอัตโนมัติ', AppLang.vi: 'Tự động làm mới: bật'});
  String get autoRefreshOff => _t({AppLang.en: 'Auto refresh off', AppLang.zh: '自动刷新：关', AppLang.ja: '自動更新：オフ', AppLang.ko: '자동 새로고침 꺼짐', AppLang.th: 'ปิดรีเฟรชอัตโนมัติ', AppLang.vi: 'Tự động làm mới: tắt'});
  String get fetching => _t({AppLang.en: 'Fetching…', AppLang.zh: '正在获取…', AppLang.ja: '取得中…', AppLang.ko: '불러오는 중…', AppLang.th: 'กำลังดึงข้อมูล…', AppLang.vi: 'Đang lấy dữ liệu…'});
  String get updatedAt => _t({AppLang.en: 'Updated', AppLang.zh: '更新于', AppLang.ja: '更新', AppLang.ko: '업데이트', AppLang.th: 'อัปเดตเมื่อ', AppLang.vi: 'Cập nhật lúc'});
  String get autoEveryMinute => _t({AppLang.en: 'auto refresh every minute', AppLang.zh: '每分钟自动刷新', AppLang.ja: '毎分自動更新', AppLang.ko: '1분마다 자동 새로고침', AppLang.th: 'รีเฟรชอัตโนมัติทุกนาที', AppLang.vi: 'tự động làm mới mỗi phút'});
  String get dataTotalShort => _t({AppLang.en: 'Total', AppLang.zh: '总量', AppLang.ja: '合計', AppLang.ko: '총량', AppLang.th: 'รวม', AppLang.vi: 'Tổng'});
  String get noUsageYet => _t({AppLang.en: 'No usage data yet, it updates after activation', AppLang.zh: '暂无流量数据，激活后自动更新', AppLang.ja: '利用データがありません。開通後に更新されます', AppLang.ko: '아직 사용량 데이터가 없습니다. 활성화 후 자동 업데이트됩니다', AppLang.th: 'ยังไม่มีข้อมูลการใช้งาน จะอัปเดตหลังเปิดใช้งาน', AppLang.vi: 'Chưa có dữ liệu dung lượng, sẽ cập nhật sau khi kích hoạt'});
  String get expiresOn => _t({AppLang.en: 'Expires', AppLang.zh: '到期', AppLang.ja: '有効期限', AppLang.ko: '만료', AppLang.th: 'หมดอายุ', AppLang.vi: 'Hết hạn'});
  String get statusIssued => _t({AppLang.en: 'Not activated', AppLang.zh: '待激活', AppLang.ja: '未開通', AppLang.ko: '활성화 대기', AppLang.th: 'ยังไม่เปิดใช้งาน', AppLang.vi: 'Chưa kích hoạt'});
  String get statusUsing => _t({AppLang.en: 'In use', AppLang.zh: '使用中', AppLang.ja: '使用中', AppLang.ko: '사용 중', AppLang.th: 'กำลังใช้งาน', AppLang.vi: 'Đang dùng'});
  String get physicalCard => _t({AppLang.en: 'Physical SIM', AppLang.zh: '实体卡', AppLang.ja: '物理SIM', AppLang.ko: '실물 카드', AppLang.th: 'ซิมการ์ด', AppLang.vi: 'SIM vật lý'});
  String get defaultCard => _t({AppLang.en: 'Default card', AppLang.zh: '默认卡', AppLang.ja: 'デフォルトカード', AppLang.ko: '기본 카드', AppLang.th: 'การ์ดหลัก', AppLang.vi: 'Thẻ mặc định'});
  String get noCardData => _t({AppLang.en: 'No card data', AppLang.zh: '暂无卡片数据', AppLang.ja: 'カード情報がありません', AppLang.ko: '카드 정보가 없습니다', AppLang.th: 'ไม่มีข้อมูลการ์ด', AppLang.vi: 'Chưa có dữ liệu thẻ'});

  // ---- plan detail ----
  String get kindSim => _t({AppLang.en: 'SIM type', AppLang.zh: '类型', AppLang.ja: '種類', AppLang.ko: '유형', AppLang.th: 'ประเภท', AppLang.vi: 'Loại'});
  String get kindPhysicalSim => _t({AppLang.en: 'Physical SIM', AppLang.zh: '实体 SIM', AppLang.ja: '物理 SIM', AppLang.ko: '실물 SIM', AppLang.th: 'ซิมการ์ด', AppLang.vi: 'SIM vật lý'});
  String get kindPhysicalCard => _t({AppLang.en: 'Physical card', AppLang.zh: '实体卡', AppLang.ja: '物理カード', AppLang.ko: '실물 카드', AppLang.th: 'การ์ดซิม', AppLang.vi: 'Thẻ vật lý'});

  // ---- plan card ----
  String get view => _t({AppLang.en: 'View', AppLang.zh: '查看', AppLang.ja: '詳細', AppLang.ko: '보기', AppLang.th: 'ดู', AppLang.vi: 'Xem'});
  String get addToCartShort => _t({AppLang.en: 'Add to cart', AppLang.zh: '加入购物车', AppLang.ja: 'カートに入れる', AppLang.ko: '장바구니에 담기', AppLang.th: 'เพิ่มลงตะกร้า', AppLang.vi: 'Thêm vào giỏ'});
}
