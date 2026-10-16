// ============================================================================
// 公式帶入面板的「?」說明視窗 —— 一個欄位一個視窗
// ============================================================================
//
// 外框照「推薦飲品」視窗（k2_drink_preview.dart）的做法：
//   · 玻璃開 → 透明 Dialog + ClipRRect + BackdropFilter + 半透明框
//   · 玻璃關 → 一般 AlertDialog
//   · 公式那一塊是資料，永遠深色實心（玻璃會降低對比）
//
// 說明文字全部放在 localization_service.dart 的 `k2_help_<api>_<段>`：
//   what  這是什麼        （必填）
//   how   怎麼算          （必填）
//   use   在推薦裡的角色   （必填）
//   note  要注意的地方     （必填）
//   ref   參考值          （選填 —— 只有真的有文獻的欄位才寫）
// 測試會檢查 13 個欄位的必填段落兩種語言都在。
// ============================================================================

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../../shared/services/localization_service.dart';
import '../../../shared/ui/glass.dart';
import 'k2_formula_panel.dart';

/// 每個欄位的說明段落（順序即顯示順序）。
const k2HelpSections = ['what', 'how', 'use', 'note', 'ref'];

/// 必填段落。`ref` 是選填。
const k2HelpRequired = ['what', 'how', 'use', 'note'];

/// 某欄位某段落的翻譯 key。
String k2HelpKey(String api, String section) => 'k2_help_${api}_$section';

/// 跳出 [row] 那個欄位的說明視窗。
Future<void> showK2FieldHelp(BuildContext context, K2FormulaRow row) {
  return showDialog<void>(
    context: context,
    // 同推薦飲品視窗:遮罩調淡,玻璃才有東西可以模糊
    barrierColor: globalGlassNotifier.value
        ? const Color.fromRGBO(0, 0, 0, 0.28)
        : null,
    builder: (ctx) => _K2FieldHelpDialog(row: row),
  );
}

class _K2FieldHelpDialog extends StatelessWidget {
  const _K2FieldHelpDialog({required this.row});

  final K2FormulaRow row;

  @override
  Widget build(BuildContext context) => globalGlassNotifier.value
      ? _glassDialog(context)
      : _materialDialog(context);

  Widget _glassDialog(BuildContext context) {
    return Dialog(
      // 不設透明的話 Material 自己的白底會擋在前面,模糊完全看不到
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
      child: ClipRRect(
        // ⚠️ 一定要裁切,否則模糊會溢出到整個畫面
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 620),
            decoration: BoxDecoration(
              color: GlassColors.shell,
              border: Border.all(color: GlassColors.shellEdge, width: 1.2),
              borderRadius: BorderRadius.circular(20),
            ),
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _titleRow(),
                const SizedBox(height: 14),
                Flexible(child: _body()),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerRight,
                  child: _closeButton(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _materialDialog(BuildContext context) => AlertDialog(
    title: _titleRow(),
    content: SizedBox(width: 560, child: _body()),
    actions: [_closeButton(context)],
  );

  Widget _titleRow() {
    final llm = row.llm;
    return Row(
      children: [
        Icon(Icons.help_outline, color: Colors.teal.shade700),
        const SizedBox(width: 8),
        Text(
          row.api,
          style: const TextStyle(
            fontFamily: 'Consolas',
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            border: Border.all(
              color: llm ? Colors.teal.shade400 : Colors.grey.shade400,
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            tr(llm ? 'k2_help_tag_llm' : 'k2_help_tag_mid'),
            style: TextStyle(
              fontSize: 11,
              color: llm ? Colors.teal.shade800 : Colors.grey.shade600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _closeButton(BuildContext context) => TextButton(
    onPressed: () => Navigator.of(context).pop(),
    child: Text(tr('k2_drink_close')),
  );

  Widget _body() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── 公式:資料區,永遠深色實心 ──
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              border: Border.all(color: Colors.black26),
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectableText(
              '${row.api} = ${row.formula}\n← ${row.inputs.join(', ')}',
              style: const TextStyle(
                fontFamily: 'Consolas',
                fontSize: 12.5,
                height: 1.6,
                color: Color(0xFFD4D4D4),
              ),
            ),
          ),
          for (final s in k2HelpSections)
            if (_has(s)) ...[
              const SizedBox(height: 14),
              Text(
                tr('k2_help_sec_$s'),
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                tr(k2HelpKey(row.api, s)),
                style: const TextStyle(fontSize: 13, height: 1.55),
              ),
            ],
        ],
      ),
    );
  }

  /// tr() 找不到 key 時會原樣回傳 key —— 用這個判斷選填段落有沒有寫。
  bool _has(String section) {
    final k = k2HelpKey(row.api, section);
    return tr(k) != k;
  }
}
