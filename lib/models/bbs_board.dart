/// A category of a BBS board with its abbreviation from the `!h` table.
class BbsCategory {
  const BbsCategory(this.abbreviation, this.name);

  final String abbreviation;
  final String name;

  Map<String, String> toJson() => {'abbr': abbreviation, 'name': name};

  factory BbsCategory.fromJson(Map<String, dynamic> json) =>
      BbsCategory(json['abbr'] as String, json['name'] as String);

  @override
  bool operator ==(Object other) =>
      other is BbsCategory &&
      other.abbreviation == abbreviation &&
      other.name == name;

  @override
  int get hashCode => Object.hash(abbreviation, name);
}

/// Sync state of one BBS board as seen from one radio.
class BbsBoard {
  const BbsBoard({
    this.epoch = '',
    this.categories = const [],
    this.retention = const {},
    this.lastId = 0,
    this.deletionSeq = 0,
    this.lastSync,
  });

  /// Retention used while the BBS has not reported one.
  static const int defaultRetentionDays = 90;

  /// Key in [retention] for categories the `R` lines do not list.
  static const String otherCategories = '*';

  /// Database instance of the BBS node; empty before the first sync.
  final String epoch;

  /// Categories in board order, from the `!h` reply.
  final List<BbsCategory> categories;

  /// Days per category abbreviation from the `R` lines; `0` = keep forever.
  final Map<String, int> retention;

  /// Highest message id in the local copy (`since_id` of the next `!x`).
  final int lastId;

  /// Highest deletion sequence number processed (`since_del` of the next `!x`).
  final int deletionSeq;

  /// Unix seconds of the last completed sync.
  final int? lastSync;

  /// Full category name for an abbreviation from a sync record. A category
  /// that is no longer configured already arrives with its full name.
  String categoryName(String token) {
    for (final category in categories) {
      if (category.abbreviation == token) return category.name;
    }
    return token;
  }

  /// Retention in days for a full category name; `0` = keep forever.
  int retentionDaysFor(String category) {
    for (final entry in categories) {
      if (entry.name == category) {
        final days = retention[entry.abbreviation];
        if (days != null) return days;
        break;
      }
    }
    return retention[otherCategories] ?? defaultRetentionDays;
  }
}
