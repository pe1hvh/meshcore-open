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

/// How a meshcore-gui BBS delivers its reply DMs, from the `X|` line of its
/// `!h x` reply (meshcore-gui 1.27.0). The app needs it to know how long the
/// BBS may spend on one reply part. [defaults] matches meshcore-gui 1.26.5
/// and is used for a BBS that does not send the line.
class BbsDeliverySettings {
  const BbsDeliverySettings({
    this.attempts = 3,
    this.floodAfter = 2,
    this.floodMinWait = const Duration(seconds: 30),
    this.waitFactor = 1.2,
    this.announced = false,
    this.checkedAt,
  });

  static const BbsDeliverySettings defaults = BbsDeliverySettings();

  /// Send attempts per reply part (`a`).
  final int attempts;

  /// Attempts along the known route before the BBS floods (`f`).
  final int floodAfter;

  /// Minimum wait of the BBS for the ACK of a flooded part (`w`).
  final Duration floodMinWait;

  /// Factor on the radio's timeout per attempt (`k`).
  final double waitFactor;

  /// The BBS sent these values; `false` for [defaults] after a `!h x` reply
  /// without the line (meshcore-gui before 1.27.0).
  final bool announced;

  /// Unix seconds of the `!h x` reply these values came from; not part of
  /// [==].
  final int? checkedAt;

  /// The same values, checked at [seconds].
  BbsDeliverySettings checked(int seconds) => BbsDeliverySettings(
    attempts: attempts,
    floodAfter: floodAfter,
    floodMinWait: floodMinWait,
    waitFactor: waitFactor,
    announced: announced,
    checkedAt: seconds,
  );

  Map<String, Object> toJson() => {
    'a': attempts,
    'f': floodAfter,
    'w': floodMinWait.inMilliseconds / 1000,
    'k': waitFactor,
    'announced': announced,
    'checkedAt': ?checkedAt,
  };

  factory BbsDeliverySettings.fromJson(Map<String, dynamic> json) =>
      BbsDeliverySettings(
        attempts: (json['a'] as num?)?.toInt() ?? defaults.attempts,
        floodAfter: (json['f'] as num?)?.toInt() ?? defaults.floodAfter,
        floodMinWait: json['w'] is num
            ? Duration(milliseconds: ((json['w'] as num) * 1000).round())
            : defaults.floodMinWait,
        waitFactor: (json['k'] as num?)?.toDouble() ?? defaults.waitFactor,
        announced: json['announced'] == true,
        checkedAt: (json['checkedAt'] as num?)?.toInt(),
      );

  @override
  bool operator ==(Object other) =>
      other is BbsDeliverySettings &&
      other.attempts == attempts &&
      other.floodAfter == floodAfter &&
      other.floodMinWait == floodMinWait &&
      other.waitFactor == waitFactor &&
      other.announced == announced;

  @override
  int get hashCode =>
      Object.hash(attempts, floodAfter, floodMinWait, waitFactor, announced);
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
    this.delivery,
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

  /// Delivery settings from the last `!h x` reply; `null` before the app
  /// asked for them.
  final BbsDeliverySettings? delivery;

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
