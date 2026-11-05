import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../store.dart';
import '../theme.dart';
import '../widgets.dart';

/// Forgot-password flow: email -> code (or reset link) -> new password.
///
/// Shares the same backend code channel as registration, so the cool-down and
/// error wording are identical. Reached from the sign-in screen only.
class ResetPasswordScreen extends StatefulWidget {
  final String initialEmail;
  const ResetPasswordScreen({super.key, this.initialEmail = ''});
  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  late final _email = TextEditingController(text: widget.initialEmail);
  final _code = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _sending = false;
  int _countdown = 0;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _email.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  void _toast(String m, {bool ok = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(m),
      backgroundColor: ok ? AppColors.success : AppColors.danger,
      behavior: SnackBarBehavior.floating,
    ));
  }

  void _startCountdown(int s) {
    _timer?.cancel();
    setState(() => _countdown = s);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _countdown--);
      if (_countdown <= 0) t.cancel();
    });
  }

  Future<void> _send() async {
    final email = _email.text.trim();
    if (email.isEmpty || !email.contains('@')) return _toast('请先填写正确的邮箱地址');
    final app = context.read<AppState>();
    setState(() => _sending = true);
    try {
      await app.sendCode(email, purpose: 'reset');
      _toast('重置验证码已发送至 $email，请查收', ok: true);
      _startCountdown(60);
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    if (email.isEmpty || !email.contains('@')) return _toast('请填写正确的邮箱地址');
    if (_code.text.trim().isEmpty) return _toast('请输入邮箱验证码');
    if (_password.text.length < 6) return _toast('新密码至少 6 位');
    final app = context.read<AppState>();
    setState(() => _busy = true);
    try {
      await app.resetPassword(email, _code.text.trim(), _password.text);
      if (!mounted) return;
      Navigator.pop(context);
      _toast('密码已重置，请用新密码登录', ok: true);
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('重置密码')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 8),
          const Text('填写注册邮箱，获取验证码后设置新密码。',
              style: TextStyle(fontSize: 13, color: AppColors.muted)),
          const SizedBox(height: 20),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: const InputDecoration(labelText: '邮箱'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _code,
            keyboardType: TextInputType.visiblePassword,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [
              LengthLimitingTextInputFormatter(6),
              FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Za-z]')),
            ],
            decoration: InputDecoration(
              labelText: '邮箱验证码',
              hintText: '6 位验证码',
              prefixIcon: const Icon(Icons.mark_email_read_outlined,
                  size: 20, color: AppColors.muted),
              suffixIcon: Padding(
                padding: const EdgeInsets.only(right: 6, top: 6, bottom: 6),
                child: TextButton(
                  onPressed: (_countdown > 0 || _sending || _busy) ? null : _send,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: const Size(0, 40),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: _sending
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_countdown > 0 ? '${_countdown}s' : '获取验证码',
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w700)),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            '验证码会发送到上面的邮箱，10 分钟内有效',
            style: TextStyle(fontSize: 11, color: AppColors.muted),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(labelText: '新密码（至少 6 位）'),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('重置密码'),
          ),
        ],
      ),
    );
  }
}

/// Sign-in / sign-up screen with email-code verification.
///
/// Registration requires a 6-character code emailed by the backend. The send
/// button owns a 60s cool-down that mirrors the server-side limit, so the user
/// gets immediate feedback instead of a 429 round-trip.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();
  final _code = TextEditingController();
  // 邀请码（选填）：注册成功后立即 claim，好友首单才能享受折扣
  final _invite = TextEditingController();

  bool _register = false;
  bool _busy = false;

  /// Set when the backend answers 404/405 to /api/auth/send-code, which means
  /// this deployment predates email verification. Registration then falls back
  /// to the old password-only flow instead of leaving the user stuck on a
  /// button that can never work.
  ///
  /// Only a 404/405 may set this. A failed *send* (SMTP down, network blip,
  /// rate limit) must never hide the code field -- that silently downgrades
  /// registration to password-only, which is exactly the bug where users saw
  /// no verification-code box at all.
  bool _codeUnsupported = false;

  /// Seconds left before another code may be requested. 0 == button enabled.
  int _countdown = 0;
  Timer? _timer;
  bool _sendingCode = false;

  @override
  void dispose() {
    _timer?.cancel();
    _email.dispose();
    _password.dispose();
    _name.dispose();
    _code.dispose();
    _invite.dispose();
    super.dispose();
  }

  void _startCountdown(int seconds) {
    _timer?.cancel();
    setState(() => _countdown = seconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _countdown = _countdown - 1);
      if (_countdown <= 0) t.cancel();
    });
  }

  void _toast(String msg, {bool ok = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: ok ? AppColors.success : AppColors.danger,
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _sendCode() async {
    final email = _email.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      _toast('请先填写正确的邮箱地址');
      return;
    }

    final app = context.read<AppState>();
    setState(() => _sendingCode = true);
    try {
      await app.sendCode(email, purpose: 'register');
      _toast('验证码已发送至 $email，请查收（含垃圾邮件箱）', ok: true);
      _startCountdown(60);
    } catch (e) {
      if (_looksUnsupported(e)) {
        if (!mounted) return;
        setState(() => _codeUnsupported = true);
        _toast('当前服务器未启用邮箱验证，可直接注册');
      } else {
        // The server's own wording already includes the wait time.
        _toast(_cleanError(e));
      }
    } finally {
      if (mounted) setState(() => _sendingCode = false);
    }
  }

  /// True when the failure is "endpoint does not exist", i.e. an older backend.
  ///
  /// Matches only on the HTTP status. Matching the literal string "not found"
  /// as well used to swallow unrelated errors (DNS failures and 502 gateway
  /// bodies both contain it), which hid the code field for good.
  bool _looksUnsupported(Object e) {
    final s = e.toString();
    return RegExp(r'\b(404|405)\b').hasMatch(s) &&
        !s.contains('502') &&
        !s.contains('503');
  }

  /// Strip the transport noise so the user sees the server's own wording.
  String _cleanError(Object e) {
    final s = e.toString();
    final i = s.indexOf('detail');
    if (i >= 0) return s.substring(i);
    return s.replaceFirst('Exception: ', '');
  }

  Future<void> _submit() async {
    final app = context.read<AppState>();
    final email = _email.text.trim();

    if (_register) {
      if (email.isEmpty || !email.contains('@')) {
        _toast('请填写正确的邮箱地址');
        return;
      }
      if (_password.text.length < 6) {
        _toast('密码至少 6 位');
        return;
      }
      if (!_codeUnsupported && _code.text.trim().isEmpty) {
        _toast('请输入邮箱验证码');
        return;
      }
    }

    setState(() => _busy = true);
    try {
      if (_register) {
        await app.register(email, _password.text, _name.text.trim(),
            code: _codeUnsupported ? '' : _code.text.trim());
        // 邀请码不是注册的硬依赖：claim 失败不该把整个注册回滚。
        final code = _invite.text.trim();
        if (code.isNotEmpty) {
          try {
            await app.api.referralClaim(code);
          } catch (_) {
            // 无效码 / 重复绑定都在这里吞掉，用户已经在注册成功后的流程里
          }
        }
      } else {
        await app.login(email, _password.text);
      }
      if (!mounted) return;
      Navigator.pop(context);
      _toast('登录成功', ok: true);
    } catch (e) {
      _toast(_cleanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openReset() {
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => ResetPasswordScreen(initialEmail: _email.text.trim())),
    );
  }

  /// Swap between login and register, clearing fields that do not carry over.
  void _toggleMode() {
    setState(() {
      _register = !_register;
      _code.clear();
      _timer?.cancel();
      _countdown = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_register ? '注册' : '登录')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          const SizedBox(height: 12),
          const Center(
            child: BrandMark(size: 76),
          ),
          const SizedBox(height: 24),

          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: const InputDecoration(labelText: '邮箱'),
          ),
          const SizedBox(height: 12),

          if (_register) ...[
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: '昵称'),
            ),
            const SizedBox(height: 12),
          ],

          TextField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(labelText: '密码'),
          ),

          // ---- verification code row (register only) ----
          // Always shown while registering unless the backend proved it has no
          // send-code endpoint. A code field the user cannot see means they
          // cannot register at all, so hiding it is the last resort.
          if (_register && !_codeUnsupported) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _code,
              keyboardType: TextInputType.visiblePassword,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [
                LengthLimitingTextInputFormatter(6),
                FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Za-z]')),
              ],
              decoration: InputDecoration(
                labelText: '邮箱验证码',
                hintText: '6 位验证码',
                prefixIcon: const Icon(Icons.mark_email_read_outlined,
                    size: 20, color: AppColors.muted),
                suffixIcon: Padding(
                  padding: const EdgeInsets.only(right: 6, top: 6, bottom: 6),
                  child: TextButton(
                    onPressed: (_countdown > 0 || _sendingCode || _busy)
                        ? null
                        : _sendCode,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      minimumSize: const Size(0, 40),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: _sendingCode
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            _countdown > 0 ? '${_countdown}s' : '获取验证码',
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w700),
                          ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '验证码会发送到上面的邮箱，10 分钟内有效',
              style: TextStyle(fontSize: 11, color: AppColors.muted),
            ),
          ],

          // ---- 邀请码（选填，注册时才有）----
          if (_register) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _invite,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [
                LengthLimitingTextInputFormatter(16),
                FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Za-z]')),
              ],
              decoration: InputDecoration(
                labelText: context.read<AppState>().t.inviteCodeOptional,
                hintText: context.read<AppState>().t.inviteCodeHint,
                prefixIcon: const Icon(Icons.card_giftcard_rounded,
                    size: 20, color: AppColors.muted),
              ),
            ),
          ],

          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : Text(_register ? '注册并登录' : '登录'),
          ),
          if (!_register) ...[
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _busy ? null : () => _openReset(),
                child: const Text('忘记密码？', style: TextStyle(fontSize: 13)),
              ),
            ),
          ],
          const SizedBox(height: 10),
          TextButton(
            onPressed: _busy ? null : _toggleMode,
            child: Text(_register ? '已有账号？去登录' : '没有账号？去注册'),
          ),
        ],
      ),
    );
  }
}
