import 'package:iconsax_plus/iconsax_plus.dart';
import 'package:material_ui/material_ui.dart';

import '../settings.dart';
import 'browser_screen.dart';

/// First run (or "change server"): ask for the TorBox STRM address and check
/// it answers `/health`. Login itself happens in the web UI afterwards.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, this.initial});
  final Uri? initial;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  late final TextEditingController _url = TextEditingController(text: widget.initial?.toString() ?? '');
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final server = ServerStore.normalize(_url.text);
    if (server == null) {
      setState(() => _error = 'Địa chỉ không hợp lệ. Ví dụ: https://media.example.com');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await probeServer(server);
    if (!mounted) return;
    setState(() => _busy = false);
    switch (result) {
      case ProbeResult.ok:
        await ServerStore.save(server);
        if (!mounted) return;
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => BrowserScreen(server: server)));
      case ProbeResult.notTorboxStrm:
        setState(() => _error = 'Máy chủ có phản hồi nhưng không phải TorBox STRM (không có /health).');
      case ProbeResult.certificate:
        setState(() => _error = 'Chứng chỉ HTTPS của máy chủ không hợp lệ.');
      case ProbeResult.unreachable:
        setState(() => _error = 'Không kết nối được tới ${server.host}. Kiểm tra địa chỉ và mạng.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final insecure = _url.text.trim().startsWith('http://');
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(IconsaxPlusBold.video_play, size: 64, color: theme.colorScheme.primary),
                const SizedBox(height: 16),
                Text(
                  'TorBox STRM',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  'Nhập địa chỉ máy chủ TorBox STRM. Bạn sẽ đăng nhập bằng tài khoản của máy chủ ở bước tiếp theo.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _url,
                  autofocus: true,
                  enabled: !_busy,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  textInputAction: TextInputAction.go,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _connect(),
                  decoration: InputDecoration(
                    labelText: 'Địa chỉ máy chủ',
                    hintText: 'https://media.example.com',
                    prefixIcon: const Icon(IconsaxPlusLinear.global),
                    border: const OutlineInputBorder(),
                    errorText: _error,
                    errorMaxLines: 3,
                    helperText: insecure ? 'HTTP không mã hoá: chỉ dùng trong mạng nội bộ.' : null,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _busy ? null : _connect,
                  icon: _busy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(IconsaxPlusLinear.login),
                  label: const Text('Kết nối'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
