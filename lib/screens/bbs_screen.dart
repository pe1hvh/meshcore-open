import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';
import '../models/bbs_board.dart';
import '../models/bbs_message.dart';
import '../models/contact.dart';
import '../services/bbs/bbs_sync_service.dart';
import '../utils/radio_guard.dart';
import '../widgets/adaptive_app_bar_title.dart';
import '../widgets/chat_day_separator.dart';
import '../widgets/empty_state.dart';
import '../widgets/mesh_ui.dart';

/// Whether the BBS is supported here: not on web, where there is no store,
/// and not in a widget tree built without the sync service.
bool bbsAvailable(BuildContext context) {
  try {
    return context.read<BbsSyncService?>() != null;
  } on ProviderNotFoundException {
    return false;
  }
}

/// Local copy of a meshcore-gui BBS: one tab for all messages and one per
/// category, newest first. Opening the screen fetches the categories and new
/// messages; pulling down fetches new messages. Without a radio the stored
/// messages stay readable.
class BbsScreen extends StatefulWidget {
  const BbsScreen({super.key, required this.contact});

  final Contact contact;

  @override
  State<BbsScreen> createState() => _BbsScreenState();
}

class _BbsScreenState extends State<BbsScreen> {
  BbsBoard? _board;
  List<BbsMessage> _messages = const [];
  bool _loaded = false;

  String get _bbsKey => widget.contact.publicKeyHex;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    await _load();
    if (!mounted || isRadioReadOnly(context.read<MeshCoreConnector>())) {
      return;
    }
    await _sync(refreshCategories: true);
  }

  Future<void> _load() async {
    if (!mounted) return;
    final service = context.read<BbsSyncService?>()!;
    final device = service.deviceKey;
    final board = device == null
        ? null
        : await service.store.board(device, _bbsKey);
    final messages = device == null
        ? const <BbsMessage>[]
        : await service.store.messages(device, _bbsKey);
    if (!mounted) return;
    setState(() {
      _board = board;
      _messages = messages;
      _loaded = true;
    });
  }

  Future<void> _sync({bool refreshCategories = false}) async {
    final connector = context.read<MeshCoreConnector>();
    if (!ensureRadioConnected(context)) return;
    final contact = connector.contacts.firstWhere(
      (c) => c.publicKeyHex == _bbsKey,
      orElse: () => widget.contact,
    );
    final result = await context.read<BbsSyncService?>()!.sync(
      contact,
      refreshCategories: refreshCategories,
    );
    if (!mounted) return;
    await _load();
    if (!mounted) return;
    final hasBoard = _board?.categories.isNotEmpty ?? false;
    final message = switch (result) {
      BbsSyncResult.done => null,
      BbsSyncResult.incomplete => context.l10n.bbs_incomplete,
      BbsSyncResult.noReply => hasBoard ? context.l10n.bbs_noReplyTitle : null,
      BbsSyncResult.failed => hasBoard ? context.l10n.bbs_failed : null,
    };
    if (message != null) {
      showDismissibleSnackBar(context, content: Text(message));
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<BbsSyncService?>()!;
    final readOnly = context.radioReadOnly;
    final syncing = service.isSyncing(_bbsKey);
    final categories = _board?.categories ?? const <BbsCategory>[];
    final title = AdaptiveAppBarTitle(
      context.l10n.bbs_title(widget.contact.name),
    );
    final refresh = IconButton(
      tooltip: context.l10n.bbs_sync,
      onPressed: readOnly || syncing ? null : () => unawaited(_sync()),
      icon: syncing
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.refresh),
    );

    if (!_loaded || categories.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: title, centerTitle: true, actions: [refresh]),
        body: SafeArea(child: _buildWithoutBoard(service, syncing, readOnly)),
      );
    }

    return DefaultTabController(
      length: categories.length + 1,
      child: Scaffold(
        appBar: AppBar(
          title: title,
          centerTitle: true,
          actions: [refresh],
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: context.l10n.bbs_tabAll),
              for (final category in categories) Tab(text: category.name),
            ],
          ),
        ),
        body: SafeArea(
          top: false,
          child: TabBarView(
            children: [
              _buildList(null, readOnly),
              for (final category in categories) _buildList(category, readOnly),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWithoutBoard(
    BbsSyncService service,
    bool syncing,
    bool readOnly,
  ) {
    if (!_loaded || syncing) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            if (_loaded) ...[
              const SizedBox(height: 16),
              Text(context.l10n.bbs_fetching),
            ],
          ],
        ),
      );
    }
    final failed = service.lastResult(_bbsKey) == BbsSyncResult.failed;
    return EmptyState(
      icon: failed ? Icons.sync_problem : Icons.lock_outline,
      title: failed ? context.l10n.bbs_failed : context.l10n.bbs_noReplyTitle,
      subtitle: failed ? null : context.l10n.bbs_noReplySubtitle,
      action: FilledButton.icon(
        onPressed: readOnly
            ? null
            : () => unawaited(_sync(refreshCategories: true)),
        icon: const Icon(Icons.refresh),
        label: Text(context.l10n.common_retry),
      ),
    );
  }

  Widget _buildList(BbsCategory? category, bool readOnly) {
    final messages = category == null
        ? _messages
        : _messages.where((m) => m.category == category.name).toList();
    final retention = category == null
        ? null
        : _board!.retentionDaysFor(category.name);
    return RefreshIndicator(
      onRefresh: readOnly ? () async {} : _sync,
      child: LayoutBuilder(
        builder: (context, constraints) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            if (retention != null) _RetentionLabel(days: retention),
            if (messages.isEmpty)
              SizedBox(
                height: constraints.maxHeight * 0.8,
                child: EmptyState(
                  icon: Icons.forum_outlined,
                  title: context.l10n.bbs_emptyTitle,
                  subtitle: context.l10n.bbs_emptySubtitle,
                ),
              )
            else
              for (final message in messages)
                _BbsMessageCard(
                  message: message,
                  showCategory: category == null,
                ),
          ],
        ),
      ),
    );
  }
}

class _RetentionLabel extends StatelessWidget {
  const _RetentionLabel({required this.days});

  final int days;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Icon(Icons.schedule, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              days == 0
                  ? context.l10n.bbs_retentionForever
                  : context.l10n.bbs_retentionDays(days),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _BbsMessageCard extends StatelessWidget {
  const _BbsMessageCard({required this.message, required this.showCategory});

  final BbsMessage message;
  final bool showCategory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final time = message.time;
    return MeshCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Sender and time share a line while they fit, else the time
          // moves below.
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            children: [
              Text(
                message.sender,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '${formatChatDayLabel(context, time)} '
                '${formatChatTime(context, time)}',
                style: meta,
              ),
            ],
          ),
          if (showCategory) Text(message.category, style: meta),
          const SizedBox(height: 6),
          SelectableText(message.text, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
