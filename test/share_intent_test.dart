import 'package:flutter_test/flutter_test.dart';
import 'package:focusflow_mobile/core/share_intent.dart';

/// What the user ends up staring at after a share depends entirely on this
/// split, and the inputs vary wildly: a bare URL, a page title plus URL, a
/// pasted paragraph. Getting it wrong produces either an unreadable list or
/// silently discarded text.
void main() {
  group('parseSharedText', () {
    test('nothing shared yields nothing', () {
      expect(parseSharedText(null), isNull);
      expect(parseSharedText(''), isNull);
      expect(parseSharedText('   '), isNull);
      expect(parseSharedText('\n\n  \n'), isNull);
    });

    test('a single short line is the title, with no description', () {
      final r = parseSharedText('Buy milk')!;
      expect(r.title, 'Buy milk');
      expect(r.description, isNull);
    });

    test('trims surrounding whitespace', () {
      expect(parseSharedText('  Buy milk  ')!.title, 'Buy milk');
    });

    test('a shared link keeps its page title as the task title', () {
      // Browsers put the page title in EXTRA_SUBJECT and the URL in EXTRA_TEXT;
      // the host side joins them subject-first, because "Flutter docs" reads far
      // better in a task list than "https://docs.flutter.dev/...".
      final r = parseSharedText('Flutter docs\nhttps://docs.flutter.dev/get-started')!;
      expect(r.title, 'Flutter docs');
      expect(r.description, 'https://docs.flutter.dev/get-started');
    });

    test('keeps every remaining line in the description', () {
      final r = parseSharedText('Title\nline one\nline two')!;
      expect(r.title, 'Title');
      expect(r.description, 'line one\nline two');
    });

    test('drops blank lines between content', () {
      final r = parseSharedText('Title\n\n\nbody')!;
      expect(r.title, 'Title');
      expect(r.description, 'body');
    });

    test('a long single paragraph is cut at a word boundary, not mid-word', () {
      final long = List.filled(60, 'word').join(' '); // ~299 chars, no newlines
      final r = parseSharedText(long)!;

      expect(r.title.endsWith('…'), isTrue);
      expect(r.title.length, lessThanOrEqualTo(kMaxSharedTitleLength + 1));
      // Cut on a space, so the last word is whole.
      expect(r.title.replaceAll('…', '').endsWith('word'), isTrue);
    });

    test('a truncated title keeps the WHOLE original as the description', () {
      // The cut point is arbitrary; discarding the head would lose text the user
      // can see they shared.
      final long = List.filled(60, 'word').join(' ');
      expect(parseSharedText(long)!.description, long);
    });

    test('a title exactly at the limit is not truncated', () {
      final exact = 'x' * kMaxSharedTitleLength;
      final r = parseSharedText(exact)!;
      expect(r.title, exact);
      expect(r.description, isNull);
    });

    test('an unbroken string past the limit still yields a usable title', () {
      // No spaces at all — the word-boundary search must not collapse the title
      // to nothing.
      final r = parseSharedText('x' * 400)!;
      expect(r.title.length, greaterThan(kMaxSharedTitleLength ~/ 2));
    });
  });

  test('SharedTask compares by value, so duplicate shares are detectable', () {
    expect(
      const SharedTask(title: 'a', description: 'b'),
      const SharedTask(title: 'a', description: 'b'),
    );
  });
}
