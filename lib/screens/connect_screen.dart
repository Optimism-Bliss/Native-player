import 'dart:async';

import 'package:iconsax_plus/iconsax_plus.dart';
import 'package:material_ui/material_ui.dart';

import '../connect_code.dart';
import '../settings.dart';
import '../tv/tv_input.dart';
import '../util/tv_mode.dart';
import '../util/links.dart';
import 'browser_screen.dart';
import 'qr_scan_screen.dart';

/// First run (or "change server"): ask for the TorBox STRM address and check
/// it answers `/health`. Login itself happens in the web UI afterwards.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, this.initial, this.initialCode});
  final Uri? initial;

  /// The server code the current server was added with (its address stays hidden).
  final String? initialCode;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  late final TextEditingController _url = TextEditingController(
    text: widget.initialCode ?? widget.initial?.toString() ?? '',
  );
  StreamSubscription<String>? _links;

  final FocusNode _field = FocusNode();

  /// TV: a paired phone can type the address or code.
  void _onFieldFocus() {
    if (!isTvDevice) return;
    if (_field.hasFocus) {
      TvInput.focus(TvField(label: 'Địa chỉ hoặc mã máy chủ', kind: 'url', value: _url.text), (action, text) async {
        if (!mounted) return false;
        if (action == 'enter') {
          await _connect();
        } else {
          setState(() => _url.text = text);
        }
        return true;
      });
    } else {
      TvInput.blur();
    }
  }

  @override
  void initState() {
    super.initState();
    _field.addListener(_onFieldFocus);
    // opened from the server's QR code (camera -> torboxstrm://connect?c=...)
    _links = AppLinks.stream.listen(_fromLink);
    for (final l in AppLinks.take((l) => codeFromLink(l) != null)) {
      _fromLink(l);
    }
  }

  void _fromLink(String raw) {
    final code = codeFromLink(raw);
    if (code == null || !mounted) return;
    _url.text = code;
    _connect();
  }

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _field.removeListener(_onFieldFocus);
    if (_field.hasFocus) TvInput.blur();
    _field.dispose();
    _links?.cancel();
    _url.dispose();
    super.dispose();
  }

  /// Server QR (torboxstrm://connect?c=TBS1-…) or a printed address, read with the camera.
  Future<void> _scan() async {
    final raw = await QrScanScreen.scan(context, title: 'Quét mã máy chủ');
    if (raw == null || !mounted) return;
    final link = appLinkFromScan(raw);
    final code = link == null ? null : codeFromLink(link);
    final value = code ?? (Uri.tryParse(raw)?.hasScheme == true && raw.startsWith('http') ? raw : null);
    if (value == null) {
      setState(() => _error = 'Mã QR này không phải mã máy chủ TorBox STRM.');
      return;
    }
    _url.text = value;
    setState(() => _error = null);
    await _connect();
  }

  Future<void> _connect() async {
    final viaCode = looksLikeServerCode(_url.text);
    final server = viaCode ? decodeServerCode(_url.text) : ServerStore.normalize(_url.text);
    if (server == null) {
      setState(
        () => _error = viaCode
            ? 'Mã máy chủ không đúng — kiểm tra lại từng ký tự (hoặc quét QR).'
            : 'Địa chỉ không hợp lệ. Ví dụ: https://media.example.com',
      );
      return;
    }
    final code = viaCode ? encodeServerCode(server) : null;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await probeServer(server);
    if (!mounted) return;
    setState(() => _busy = false);
    switch (result) {
      case ProbeResult.ok:
        await ServerStore.save(server, viaCode: code);
        if (!mounted) return;
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => BrowserScreen(server: server)));
      case ProbeResult.notTorboxStrm:
        setState(() => _error = 'Máy chủ có phản hồi nhưng không phải TorBox STRM (không có /health).');
      case ProbeResult.certificate:
        setState(() => _error = 'Chứng chỉ HTTPS của máy chủ không hợp lệ.');
      case ProbeResult.unreachable:
        setState(
          () => _error =
              'Không kết nối được tới ${viaCode ? 'máy chủ' : server.host}. Kiểm tra ${viaCode ? 'mã' : 'địa chỉ'} và mạng.',
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final insecure = _url.text.trim().startsWith('http://');
    final isCode = looksLikeServerCode(_url.text);
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
                  'Nhập địa chỉ hoặc mã máy chủ (TBS1-…) TorBox STRM. Bạn sẽ đăng nhập bằng tài khoản của máy chủ ở bước tiếp theo.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _url,
                  focusNode: _field,
                  autofocus: true,
                  enabled: !_busy,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  textInputAction: TextInputAction.go,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _connect(),
                  decoration: InputDecoration(
                    labelText: 'Địa chỉ hoặc mã máy chủ',
                    hintText: 'https://media.example.com hoặc TBS1-…',
                    prefixIcon: Icon(isCode ? IconsaxPlusLinear.key : IconsaxPlusLinear.global),
                    border: const OutlineInputBorder(),
                    errorText: _error,
                    errorMaxLines: 3,
                    suffixIcon: QrScanScreen.available && !isTvDevice
                        ? IconButton(
                            tooltip: 'Quét QR mã máy chủ',
                            icon: const Icon(IconsaxPlusLinear.scan_barcode),
                            onPressed: _busy ? null : _scan,
                          )
                        : null,
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
