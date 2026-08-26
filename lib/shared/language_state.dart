// ============================================================================
// 全域語言狀態 - 所有模式共用
// ============================================================================
// 統一的語言設定，確保不管在哪個頁面切換語言，
// ModeSelectionPage、Main 模式、BodyDoor 模式都會同步。
// ============================================================================

import 'package:flutter/material.dart';

/// 支援的語言列表（全域共用）
enum AppLanguage {
  zhTW, // 繁體中文
  en,   // 英文
}

/// 語言顯示名稱
extension AppLanguageExtension on AppLanguage {
  String get displayName {
    switch (this) {
      case AppLanguage.zhTW:
        return '繁體中文';
      case AppLanguage.en:
        return 'English';
    }
  }

  String get code {
    switch (this) {
      case AppLanguage.zhTW:
        return 'zh-TW';
      case AppLanguage.en:
        return 'en';
    }
  }
}

/// 全域語言狀態（唯一實例）
/// 所有模式的 LocalizationService 都指向這個 ValueNotifier
final ValueNotifier<AppLanguage> globalLanguageNotifier =
    ValueNotifier(AppLanguage.zhTW);
