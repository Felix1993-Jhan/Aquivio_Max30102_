// ============================================================================
// SettingsPage - 設定頁（精簡版：僅語言切換）
// ============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_firmware_tester_unified/shared/services/localization_service.dart';
import 'package:flutter_firmware_tester_unified/shared/ui/glass.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppLanguage>(
      valueListenable: LocalizationService().currentLanguageNotifier,
      builder: (context, currentLang, _) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr('settings'),
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 24),
              Card(
                elevation: 1,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.language, color: Colors.teal),
                          const SizedBox(width: 12),
                          Text(
                            tr('language_setting'),
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 12,
                        children: AppLanguage.values.map((lang) {
                          final selected = lang == currentLang;
                          return ChoiceChip(
                            label: Text(lang.displayName),
                            selected: selected,
                            onSelected: (_) {
                              if (!selected) {
                                LocalizationService().setLanguage(lang);
                              }
                            },
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _glassCard(),
            ],
          ),
        );
      },
    );
  }

  /// 玻璃質感開關。
  ///
  /// 做成執行期可切換（而不是編譯期常數），理由有兩個：
  ///   ① 可以隨時一鍵比較兩種樣子，不用重新編譯
  ///   ② **掉幀時可以當場關掉** —— 每個 BackdropFilter 都會強制一個
  ///      save layer 並且每一幀重算，K2 頁的波形圖本來就 10Hz 在重畫
  Widget _glassCard() {
    return ValueListenableBuilder<bool>(
      valueListenable: globalGlassNotifier,
      builder: (context, glass, _) => Card(
        elevation: 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.blur_on, color: Colors.teal),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      tr('glass_setting'),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Switch(
                    value: glass,
                    onChanged: (v) => globalGlassNotifier.value = v,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                tr('glass_setting_hint'),
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade600,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
