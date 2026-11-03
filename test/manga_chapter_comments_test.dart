import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/features/reader/manga_chapter_comments.dart';

void main() {
  test('portable discussion cache keeps text/order but never account image credentials', () {
    const content = ChapterContent(
      images: ['https://images.example/1.jpg'],
      imageHeaders: {
        'Referer': 'https://reader.example/chapter/1',
        'User-Agent': 'Source client',
        'Authorization': 'Token must-not-be-exported',
        'Cookie': 'session=must-not-be-exported',
      },
      commentMode: 'separate',
      comments: [
        ChapterComment(author: '甲', text: '<b>普通文本</b>\n第二行', replyTo: '乙'),
        ChapterComment(author: '丙', text: '最后一条'),
      ],
    );
    final encoded = jsonEncode(content.toJson());
    expect(encoded, isNot(contains('must-not-be-exported')));
    final restored = ChapterContent.fromJson(jsonDecode(encoded))!;
    expect(restored.images.single, content.images.single);
    expect(restored.imageHeaders, {
      'Referer': 'https://reader.example/chapter/1',
      'User-Agent': 'Source client',
    });
    expect(restored.comments.map((comment) => comment.author), ['甲', '丙']);
    expect(restored.comments.first.text, '<b>普通文本</b>\n第二行');
    expect(restored.comments.first.replyTo, '乙');
    expect(restored.commentMode, 'separate');
    expect(ChapterContent.fromJson(const {'comments': <Object?>[], 'commentMode': 'merge'})!.isEmpty, isFalse);
    expect(ChapterContent.fromJson(const {'images': <String>[]}), isNull);
  });

  testWidgets('discussion pagination exposes later comments and renders untrusted text literally', (tester) async {
    final comments = [
      for (var index = 0; index < 23; index++)
        ChapterComment(author: '作者 $index', text: index == 0 ? '<script>原样显示</script>' : '评论 $index'),
    ];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MangaChapterComments(comments: comments, mode: 'separate'))));
    expect(find.text('<script>原样显示</script>'), findsOneWidget);
    expect(find.text('吐槽 1/2'), findsOneWidget);
    await tester.drag(find.byType(PageView), const Offset(-700, 0));
    await tester.pumpAndSettle();
    expect(find.text('评论 22'), findsOneWidget);
    expect(find.text('吐槽 2/2'), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: MangaChapterComments(comments: []))));
    expect(find.text('暂无吐槽'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
