import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../store.dart';
import '../theme.dart';

/// Customer-facing support chat. The device keeps an opaque `session_key` so the
/// thread survives restarts; messages are exchanged with /api/support/*.
class SupportChatScreen extends StatefulWidget {
  const SupportChatScreen({super.key});

  @override
  State<SupportChatScreen> createState() => _SupportChatScreenState();
}

class _SupportChatScreenState extends State<SupportChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  SupportChat? _chat;
  String? _sessionKey;
  bool _loading = true;
  bool _sending = false;
  bool _failed = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    final app = context.read<AppState>();
    final sp = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() { _loading = true; _failed = false; });
    _sessionKey = sp.getString('support_session');
    SupportChat? chat;
    // 1) try the saved thread
    if (_sessionKey != null && _sessionKey!.isNotEmpty) {
      try {
        chat = await app.api.supportFetch(_sessionKey!);
      } catch (_) {
        chat = null; // stale -> recreate below
      }
    }
    // 2) create a fresh thread (also passes the key so a 404 retry is idempotent)
    if (chat == null) {
      try {
        chat = await app.api.supportStart(
          name: app.user?.fullName ?? '',
          email: app.user?.email ?? '',
          subject: '在线咨询',
          sessionKey: _sessionKey ?? '',
        );
        _sessionKey = chat.sessionKey;
        await sp.setString('support_session', _sessionKey!);
      } catch (e) {
        if (mounted) setState(() { _loading = false; _failed = true; });
        return;
      }
    }
    if (!mounted) return;
    setState(() { _chat = chat; _loading = false; _failed = false; });
    _scrollDown();
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 6), (_) => _refresh());
  }

  Future<void> _refresh() async {
    if (_sessionKey == null) return;
    try {
      final chat = await context.read<AppState>().api.supportFetch(_sessionKey!);
      if (!mounted) return;
      final grew = chat.messages.length != (_chat?.messages.length ?? 0);
      setState(() => _chat = chat);
      if (grew) _scrollDown();
    } catch (_) {}
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending || _sessionKey == null) return;
    setState(() => _sending = true);
    _input.clear();
    try {
      final chat = await context.read<AppState>().api.supportSend(_sessionKey!, text);
      if (mounted) setState(() => _chat = chat);
      _scrollDown();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('发送失败：$e'), backgroundColor: AppColors.danger));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final msgs = _chat?.messages ?? [];
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        titleSpacing: 0,
        title: Row(
          children: [
            Container(
              width: 36, height: 36,
              decoration: const BoxDecoration(gradient: AppColors.heroBlue, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: const Icon(Icons.support_agent, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 10),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('在线客服', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.text)),
                Row(children: [
                  _Dot(),
                  SizedBox(width: 5),
                  Text('通常几分钟内回复', style: TextStyle(fontSize: 11.5, color: AppColors.textSub, fontWeight: FontWeight.w400)),
                ]),
              ],
            ),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed
              ? _failure()
              : Column(
                  children: [
                    Expanded(
                      child: msgs.isEmpty
                          ? _empty()
                          : ListView.builder(
                              controller: _scroll,
                              padding: const EdgeInsets.fromLTRB(14, 16, 14, 12),
                              itemCount: msgs.length + 1,
                              itemBuilder: (_, i) {
                                if (i == 0) return _agentBar();
                                return _bubble(msgs[i - 1]);
                              },
                            ),
                    ),
                    if (_chat != null && _chat!.rating == 0 && _chat!.status == 'closed')
                      _rateBanner(),
                    _composer(),
                  ],
                ),
    );
  }

  Widget _failure() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 74, height: 74,
              decoration: BoxDecoration(color: const Color(0xFFFFF1F1), borderRadius: BorderRadius.circular(22)),
              child: const Icon(Icons.wifi_off_rounded, color: AppColors.danger, size: 34),
            ),
            const SizedBox(height: 16),
            const Text('连接客服失败', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            const SizedBox(
              width: 250,
              child: Text('请检查网络后重试。如果一直失败，可稍后再试。',
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: AppColors.textSub, height: 1.5)),
            ),
            const SizedBox(height: 18),
            ElevatedButton.icon(onPressed: _boot, icon: const Icon(Icons.refresh, size: 18), label: const Text('重试')),
          ],
        ),
      );

  Widget _agentBar() {
    final who = _chat?.agentName.isNotEmpty == true ? _chat!.agentName : '客服小助手';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: AppColors.sky, borderRadius: BorderRadius.circular(20)),
          child: Text('为您服务：$who', style: const TextStyle(fontSize: 12, color: AppColors.primary, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }

  Widget _rateBanner() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: const Color(0xFFFFF8E6), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFFFE0A3))),
      child: Row(
        children: [
          const Expanded(child: Text('本次服务已结束，为客服评分：', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600))),
          ...List.generate(5, (i) => GestureDetector(
                onTap: () => _rate(i + 1),
                child: const Padding(padding: EdgeInsets.symmetric(horizontal: 2), child: Icon(Icons.star_border_rounded, color: AppColors.gold, size: 26)),
              )),
        ],
      ),
    );
  }

  Future<void> _rate(int stars) async {
    if (_sessionKey == null) return;
    try {
      final c = await context.read<AppState>().api.supportRate(_sessionKey!, stars, '');
      if (mounted) setState(() => _chat = c);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('感谢您的评价！'), backgroundColor: AppColors.success, behavior: SnackBarBehavior.floating));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('提交失败：$e'), backgroundColor: AppColors.danger));
      }
    }
  }

  Widget _empty() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 74, height: 74,
              decoration: BoxDecoration(color: AppColors.sky, borderRadius: BorderRadius.circular(22)),
              child: const Icon(Icons.chat_bubble_outline_rounded, color: AppColors.primary, size: 34),
            ),
            const SizedBox(height: 16),
            const Text('有什么可以帮您？', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            const SizedBox(
              width: 240,
              child: Text('发送您的问题，客服会尽快回复。可咨询激活、退款、套餐等问题。',
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: AppColors.textSub, height: 1.5)),
            ),
          ],
        ),
      );

  Widget _bubble(SupportMessage m) {
    final me = !m.isAgent;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: me ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!me) _avatar(),
          if (!me) const SizedBox(width: 8),
          Flexible(
            child: Container(
              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                gradient: me ? AppColors.heroBlue : null,
                color: me ? null : Colors.white,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(me ? 16 : 4),
                  bottomRight: Radius.circular(me ? 4 : 16),
                ),
                boxShadow: const [BoxShadow(color: Color(0x0F1E3A8A), blurRadius: 10, offset: Offset(0, 4))],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (m.imageUrl.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(bottom: m.body.isEmpty ? 0 : 6),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.network(m.imageUrlResolved, width: 180, fit: BoxFit.cover,
                            errorBuilder: (_, e, s) => const SizedBox.shrink()),
                      ),
                    ),
                  if (m.body.isNotEmpty)
                    Text(m.body, style: TextStyle(fontSize: 14.5, height: 1.4, color: me ? Colors.white : AppColors.text)),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '${m.isAgent ? (m.agentName.isNotEmpty ? m.agentName : '客服') : '我'} · ${_hm(m.createdAt)}',
                      style: TextStyle(fontSize: 10, color: me ? Colors.white70 : AppColors.muted),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (me) const SizedBox(width: 8),
          if (me) _avatar(me: true),
        ],
      ),
    );
  }

  Widget _avatar({bool me = false}) => Container(
        width: 32, height: 32,
        decoration: BoxDecoration(
          color: me ? AppColors.primary.withValues(alpha: 0.12) : AppColors.sky,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(me ? Icons.person : Icons.support_agent, size: 17, color: me ? AppColors.primary : AppColors.primary),
      );

  Widget _composer() {
    return Container(
      padding: EdgeInsets.fromLTRB(12, 10, 12, 10 + MediaQuery.of(context).padding.bottom),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: '输入消息…',
                filled: true,
                fillColor: AppColors.bg,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _send,
            child: Container(
              width: 46, height: 46,
              decoration: const BoxDecoration(gradient: AppColors.heroBlue, shape: BoxShape.circle),
              child: _sending
                  ? const Padding(padding: EdgeInsets.all(13), child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send_rounded, color: Colors.white, size: 21),
            ),
          ),
        ],
      ),
    );
  }

  String _hm(DateTime? d) {
    if (d == null) return '';
    final l = d.toLocal();
    final hh = l.hour.toString().padLeft(2, '0');
    final mm = l.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
}

class _Dot extends StatelessWidget {
  const _Dot();
  @override
  Widget build(BuildContext context) => Container(
        width: 6, height: 6,
        decoration: const BoxDecoration(color: AppColors.success, shape: BoxShape.circle),
      );
}
