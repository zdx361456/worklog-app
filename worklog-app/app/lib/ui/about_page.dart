/// P12b · 关于 / 数据说明页（**Wave C1 新建**，P12 从属子页，`07:907` 不计入 13 页）。
///
/// 契约来源：`docs/07-UI实现规格.md` §3.12「关于 / 数据说明（内容要求，三条缺一不可）」
/// （`07:605` / `07:609-613`）；`02-需求与验收.md` §D.10 `AC-P12-04`；
/// 实现设计：`14-WaveC1-实现设计.md` §5。
///
/// **三条文案缺一不可（AC-P12-04，逐字，见 §5）**：
///   ① 数据只存本机（AC-44）
///   ② 必须自己备份（A8 前提 / PRD §1.4-3）
///   ③ 基础版剩余 = 应收 − 已收、不含借支（`03 §5.2` 对策 1）
library;

import 'package:flutter/material.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('关于 / 数据说明')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: const [
          // ① AC-P12-04 第 1 条（AC-44）
          _AboutSection(
            icon: Icons.phone_android_outlined,
            title: '数据只存本机',
            body: '账目只保存在这台手机上，不上传、不需要登录。',
          ),
          // ② AC-P12-04 第 2 条（A8 前提）
          _AboutSection(
            icon: Icons.backup_outlined,
            title: '必须自己备份',
            body: '手机丢失/换机/误删后无法找回，请定期到「导出备份」导出文件。',
          ),
          // ③ AC-P12-04 第 3 条（03 §5.2 对策 1，含对策 2 推荐做法）
          _AboutSection(
            icon: Icons.calculate_outlined,
            title: '基础版不含借支',
            body: '基础版剩余 = 应收 − 已收，不包含借支；'
                '如公司有预支，请临时记为一笔收款并在备注写"借支"，二期会正式支持。',
          ),
        ],
      ),
    );
  }
}

class _AboutSection extends StatelessWidget {
  const _AboutSection({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Text(title,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 8),
            Text(body, style: const TextStyle(fontSize: 15, height: 1.5)),
          ],
        ),
      ),
    );
  }
}
