// ============================================================================
// SplashScreen - 啟動畫面
// ============================================================================
// 功能：顯示應用程式啟動畫面，持續指定時間後淡出進入主程式
// ============================================================================

import 'package:flutter/material.dart';

class SplashScreen extends StatefulWidget {
  final Widget child;
  final Duration duration;
  final Duration fadeDuration;

  const SplashScreen({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 1500),
    this.fadeDuration = const Duration(milliseconds: 500),
  });

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  bool _showSplash = true;
  bool _startFadeOut = false;

  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();

    // 初始化淡出動畫控制器
    _fadeController = AnimationController(
      vsync: this,
      duration: widget.fadeDuration,
    );

    _fadeAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _fadeController, curve: Curves.easeOut),
    );

    // 監聽動畫完成
    _fadeController.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() {
          _showSplash = false;
        });
      }
    });

    _startTimer();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  void _startTimer() {
    Future.delayed(widget.duration, () {
      if (mounted) {
        setState(() {
          _startFadeOut = true;
        });
        _fadeController.forward();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_showSplash) {
      return AnimatedBuilder(
        animation: _fadeAnimation,
        builder: (context, child) {
          return Opacity(
            opacity: _startFadeOut ? _fadeAnimation.value : 1.0,
            child: child,
          );
        },
        child: Scaffold(
          body: Container(
            width: double.infinity,
            height: double.infinity,
            decoration: const BoxDecoration(
              // 漸層背景，從青色到藍紫色（與圖標顏色相配）
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF1A9A9A),  // 青色
                  Color(0xFF2E7D9A),  // 藍青色
                  Color(0xFF4A5A9A),  // 藍紫色
                ],
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Logo 圖片 - 放射狀漸層背景（中心白色，邊緣融入背景）
                Expanded(
                  child: Center(
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // 白色漸層圓圈背景（相對 Logo 向上偏移 50）
                        Transform.translate(
                          offset: const Offset(0, -20),  // 白色圓圈相對向上 50
                          child: Container(
                            width: 576,
                            height: 576,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              // 放射狀漸層：中心白色 → 邊緣透明
                              gradient: RadialGradient(
                                center: Alignment.center,
                                radius: 0.5,  // 控制漸層範圍
                                colors: [
                                  Colors.white,                              // 中心：純白
                                  Colors.white.withValues(alpha: 0.95),      // 略微透明
                                  Colors.white.withValues(alpha: 0.7),       // 漸變中
                                  const Color(0xFF2E9A9A).withValues(alpha: 0.3),  // 融入背景色
                                  const Color(0xFF2E7D9A).withValues(alpha: 0.0),  // 完全透明
                                ],
                                stops: const [0.0, 0.4, 0.6, 0.85, 1.0],
                              ),
                            ),
                          ),
                        ),
                        // Logo 圖片（置中）
                        SizedBox(
                          width: 304,
                          height: 304,
                          child: Image.asset(
                            'assets/images/logo.png',
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) {
                              // 如果圖片載入失敗，顯示預設圖標
                              return const Icon(
                                Icons.memory,
                                size: 100,
                                color: Color(0xFF2E7D9A),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // 底部文字
                Padding(
                  padding: const EdgeInsets.only(bottom: 50),
                  child: Column(
                    children: [
                      const Text(
                        'Aquivio Firmware Tester Unified',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          letterSpacing: 1.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '© 2026 Aquivio',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return widget.child;
  }
}
