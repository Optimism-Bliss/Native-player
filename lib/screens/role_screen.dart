import 'package:iconsax_plus/iconsax_plus.dart';
import 'package:material_ui/material_ui.dart';

import '../tv/tv_home.dart';
import '../util/tv_mode.dart';
import 'browser_screen.dart';
import 'connect_screen.dart';

/// First start on Android (and "Đổi vai trò thiết bị"): is this the phone
/// that browses, or the TV that plays? Works with touch and with a D-pad;
/// the suggestion from Android has the focus.
class RoleScreen extends StatelessWidget {
  const RoleScreen({super.key, this.server});
  final Uri? server;

  static Widget homeFor(Uri? server) => isTvDevice
      ? TvHome(server: server)
      : server == null
      ? const ConnectScreen()
      : BrowserScreen(server: server);

  Future<void> _pick(BuildContext context, {required bool tv}) async {
    await saveRole(tv: tv);
    if (!context.mounted) return;
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute<void>(builder: (_) => homeFor(server)), (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final wide = MediaQuery.sizeOf(context).width >= 640;
    final cards = [
      _RoleCard(
        icon: IconsaxPlusLinear.mobile,
        title: 'Điện thoại / máy tính',
        detail: 'Duyệt phim, phát trên máy này, hoặc chọn "Phát trên TV" và làm điều khiển cho TV.',
        autofocus: !looksLikeTv,
        onTap: () => _pick(context, tv: false),
      ),
      _RoleCard(
        icon: IconsaxPlusLinear.monitor,
        title: 'TV',
        detail:
            'Hiện mã QR để điện thoại kết nối, nhận phim từ điện thoại và phát toàn màn hình. Điều khiển bằng remote.',
        autofocus: looksLikeTv,
        onTap: () => _pick(context, tv: true),
      ),
    ];
    return Scaffold(
      backgroundColor: const Color(0xFF0B0D12),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Thiết bị này dùng làm gì?', style: text.headlineSmall, textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Text(
                    'Đổi lại được sau trong menu.${looksLikeTv ? ' Máy này có vẻ là TV.' : ''}',
                    style: text.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  if (wide)
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: cards[0]),
                          const SizedBox(width: 16),
                          Expanded(child: cards[1]),
                        ],
                      ),
                    )
                  else ...[
                    cards[0],
                    const SizedBox(height: 12),
                    cards[1],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.icon,
    required this.title,
    required this.detail,
    required this.onTap,
    this.autofocus = false,
  });
  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        autofocus: autofocus,
        onTap: onTap,
        focusColor: scheme.primary.withValues(alpha: 0.25),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 40, color: scheme.primary),
              const SizedBox(height: 12),
              Text(title, style: text.titleLarge),
              const SizedBox(height: 6),
              Text(detail, style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}
