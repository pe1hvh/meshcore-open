import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/bbs_board.dart';
import 'package:meshcore_open/services/bbs/bbs_protocol.dart';

import 'meshcore_gui_replies.dart';

String joined(List<String> dms) => dms.join('\n');

final epoch = guiSync00.first.split('|')[1];

const categories = [
  BbsCategory('A', 'ADDRESSES'),
  BbsCategory('U', 'URGENT'),
  BbsCategory('S', 'STATUS'),
  BbsCategory('ME', 'MEDICAL'),
  BbsCategory('MI', 'MISSING'),
];

const longText =
    'Lange melding met accenten é ü ø en emoji 📡 Lange melding met accenten '
    'é ü ø en emoji 📡 Lange melding met accenten é ü ø en emoji 📡 Lange '
    'melding met accenten é ü ø en emoji 📡 Lange melding met accenten é ü ø '
    'en emoji 📡 Lange melding met accenten é ü ø en emoji 📡';

void main() {
  group('commands', () {
    test('build the DM texts', () {
      expect(BbsProtocol.helpCommand, '!h');
      expect(BbsProtocol.syncCommand(12, 3), '!x 12 3');
      expect(BbsProtocol.postCommand('U', 'Dijk lekt'), '!p U Dijk lekt');
    });
  });

  group('parseHelp', () {
    test('reads the abbreviation table in board order', () {
      expect(BbsProtocol.parseHelp(joined(guiHelp)), categories);
    });

    test('accepts category names with spaces', () {
      expect(BbsProtocol.parseHelp('BBS\n!p ...\nA=ALL CALLS U=URGENT'), const [
        BbsCategory('A', 'ALL CALLS'),
        BbsCategory('U', 'URGENT'),
      ]);
    });

    test('a board without categories gives an empty list', () {
      expect(BbsProtocol.parseHelp('BBS\n!p ...'), isEmpty);
      expect(BbsProtocol.parseHelp('BBS\n!p ...\nRegions: Zwolle'), isEmpty);
    });

    test('other text is not a help reply', () {
      expect(BbsProtocol.parseHelp('Hallo'), isNull);
      expect(BbsProtocol.parseHelp(''), isNull);
    });
  });

  group('parsePostedId', () {
    test('reads the id from the confirmation', () {
      expect(BbsProtocol.parsePostedId(joined(guiPost)), 14);
      expect(BbsProtocol.parsePostedId('Unknown category'), isNull);
    });
  });

  group('parseSync', () {
    test('first reply: header, retention, records and deletions', () {
      final reply = BbsProtocol.parseSync(joined(guiSync00))!;
      expect(reply.epoch, epoch);
      expect(reply.count, 10);
      expect(reply.more, isTrue);
      expect(reply.deletionSeq, 1);
      expect(reply.deletionCount, 1);
      expect(reply.lineCount, 14);
      expect(reply.receivedLines, 14);
      expect(reply.retention, {
        '*': 90,
        'A': 0,
        'U': 90,
        'S': 30,
        'ME': 90,
        'MI': 90,
      });
      expect(reply.records.map((r) => r.id), [1, 3, 4, 5, 6, 7, 8, 9, 10, 11]);
      expect(reply.deletedIds, [2]);
      expect(reply.isComplete, isTrue);

      final first = reply.records.first;
      expect(first.timestamp, 4102444800);
      expect(first.category, 'U');
      expect(first.region, 'Zwolle');
      expect(first.sender, 'PE1HVH');
      expect(first.text, 'Dijk Zwolle-Zuid lekt bij gemaal');
    });

    test('text keeps its | and the sender has it replaced', () {
      final record = BbsProtocol.parseSync(
        joined(guiSync00),
      )!.records.firstWhere((r) => r.id == 3);
      expect(record.sender, 'PD/0XYZ');
      expect(record.text, 'Repeater Hattem a|b weer online');
    });

    test('line breaks arrive as spaces', () {
      final record = BbsProtocol.parseSync(
        joined(guiSync00),
      )!.records.firstWhere((r) => r.id == 4);
      expect(record.text, 'Regel 1 Regel 2');
    });

    test('continuation lines across DMs restore multi-byte text', () {
      final record = BbsProtocol.parseSync(
        joined(guiSync00),
      )!.records.firstWhere((r) => r.id == 6);
      expect(record.text, longText);
    });

    test('a removed category arrives with its full name', () {
      final reply = BbsProtocol.parseSync(joined(guiSync00))!;
      final board = BbsBoard(categories: categories);
      final messages = reply.messagesFor(board);
      expect(messages.firstWhere((m) => m.id == 5).category, 'OLD');
      expect(messages.firstWhere((m) => m.id == 1).category, 'URGENT');
      expect(messages.firstWhere((m) => m.id == 7).category, 'MISSING');
    });

    test('follow-up and empty replies', () {
      final next = BbsProtocol.parseSync(joined(guiSync100))!;
      expect(next.more, isFalse);
      expect(next.records.map((r) => r.id), [11, 12, 13]);
      expect(next.isComplete, isTrue);

      final empty = BbsProtocol.parseSync(joined(guiSync131))!;
      expect(empty.count, 0);
      expect(empty.records, isEmpty);
      expect(empty.deletedIds, isEmpty);
      expect(empty.isComplete, isTrue);
    });

    test('a space at the cut of a long record is kept', () {
      final record = BbsProtocol.parseSync(
        joined(guiSync100),
      )!.records.firstWhere((r) => r.id == 13);
      expect(record.text, '${'x' * 135} woord');
    });

    test('a reply cut short leaves out its last record', () {
      final reply = BbsProtocol.parseSync(guiSync00.take(2).join('\n'))!;
      expect(reply.receivedLines, 5);
      expect(reply.isComplete, isFalse);
      expect(reply.records.map((r) => r.id), [1, 3, 4]);
    });

    test('a reply cut inside continuation lines leaves out that record', () {
      final reply = BbsProtocol.parseSync(guiSync00.take(4).join('\n'))!;
      expect(reply.isComplete, isFalse);
      expect(reply.records.map((r) => r.id), [1, 3, 4, 5]);
    });

    test('a reply cut after its records keeps them all', () {
      final reply = BbsProtocol.parseSync(
        'X1|1|1|0|9|9|4\nR|*:90\n1|1000|U||PE1HVH|Dijk lekt\n-3,4,5',
      )!;
      expect(reply.isComplete, isFalse);
      expect(reply.records.map((r) => r.id), [1]);
      expect(reply.deletedIds, [3, 4, 5]);
    });

    test('a reply cut after the first part of a record leaves it out', () {
      final reply = BbsProtocol.parseSync(guiSync100.take(2).join('\n'))!;
      expect(reply.isComplete, isFalse);
      expect(reply.records.map((r) => r.id), [11, 12]);
    });

    test('the usage line is not a sync reply', () {
      expect(BbsProtocol.parseSync(joined(guiUsage)), isNull);
    });

    test('malformed replies throw', () {
      expect(() => BbsProtocol.parseSync('X1|1|0|0|0'), throwsFormatException);
      expect(
        () => BbsProtocol.parseSync('X1|1|0|0|0|0'),
        throwsFormatException,
      );
      expect(
        () => BbsProtocol.parseSync('X1|1|1|0|0|0|1\n+5|orphan'),
        throwsFormatException,
      );
      expect(
        () => BbsProtocol.parseSync('X1|1|1|0|0|0|1\n5|1|U|'),
        throwsFormatException,
      );
      expect(
        () => BbsProtocol.parseSync('X1|1|1|0|0|0|1\nhallo'),
        throwsFormatException,
      );
      expect(
        () => BbsProtocol.parseSync('X1|1|0|0|0|0|0\nR|*:90'),
        throwsFormatException,
      );
    });
  });

  group('BbsBoard.retentionDaysFor', () {
    const board = BbsBoard(
      categories: categories,
      retention: {'*': 60, 'A': 0, 'S': 30},
    );

    test('uses the category, then *, then 90 days', () {
      expect(board.retentionDaysFor('ADDRESSES'), 0);
      expect(board.retentionDaysFor('STATUS'), 30);
      expect(board.retentionDaysFor('URGENT'), 60);
      expect(board.retentionDaysFor('OLD'), 60);
      expect(
        const BbsBoard(categories: categories).retentionDaysFor('URGENT'),
        BbsBoard.defaultRetentionDays,
      );
    });
  });
}
