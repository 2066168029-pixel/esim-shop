import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../store.dart';
import '../theme.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController(text: 'demo@esim.local');
  final _password = TextEditingController(text: 'demo123');
  final _name = TextEditingController();
  bool _register = false;
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final app = context.read<AppState>();
    setState(() => _busy = true);
    try {
      if (_register) {
        await app.register(_email.text.trim(), _password.text, _name.text.trim());
      } else {
        await app.login(_email.text.trim(), _password.text);
      }
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('登录成功'),
        backgroundColor: AppColors.success,
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$e'),
        backgroundColor: AppColors.danger,
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_register ? '注册' : '登录')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 20),
          const Center(
            child: CircleAvatar(
              radius: 34,
              backgroundColor: AppColors.primary,
              child: Icon(Icons.sim_card, color: Colors.white, size: 34),
            ),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: '邮箱'),
          ),
          const SizedBox(height: 12),
          if (_register) ...[
            TextField(controller: _name, decoration: const InputDecoration(labelText: '昵称')),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(labelText: '密码'),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Text(_register ? '注册并登录' : '登录'),
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: () => setState(() => _register = !_register),
            child: Text(_register ? '已有账号？去登录' : '没有账号？去注册'),
          ),
          const SizedBox(height: 20),
          const Center(
            child: Text('演示账号：demo@esim.local / demo123\n管理员：admin@esim.local / admin123',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: AppColors.muted)),
          ),
        ],
      ),
    );
  }
}
