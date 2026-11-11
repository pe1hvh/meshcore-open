import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../helpers/utf8_length_limiter.dart';
import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';
import '../models/bbs_board.dart';
import '../models/bbs_message.dart';
import '../models/contact.dart';
import '../services/bbs/bbs_protocol.dart';
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

  /// With [quiet] the result is not reported, so the message of the action
  /// that started this sync stays visible.
  Future<void> _sync({
    bool refreshCategories = false,
    bool quiet = false,
  }) async {
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
    if (!mounted || quiet) return;
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

  Future<void> _post(BbsCategory initial) async {
    final draft = await showDialog<(BbsCategory, String)>(
      context: context,
      builder: (context) =>
          _BbsPostDialog(categories: _board!.categories, initial: initial),
    );
    if (draft == null || !mounted || !ensureRadioConnected(context)) return;
    final connector = context.read<MeshCoreConnector>();
    final contact = connector.contacts.firstWhere(
      (c) => c.publicKeyHex == _bbsKey,
      orElse: () => widget.contact,
    );
    final outcome = await context.read<BbsSyncService?>()!.post(
      contact,
      draft.$1.abbreviation,
      draft.$2,
    );
    if (!mounted) return;
    final message = switch (outcome.result) {
      BbsPostResult.posted => context.l10n.bbs_posted,
      BbsPostResult.rejected => context.l10n.bbs_postRejected(
        outcome.reply ?? '',
      ),
      BbsPostResult.noReply => context.l10n.bbs_postNoReply,
      BbsPostResult.failed => context.l10n.bbs_failed,
    };
    showDismissibleSnackBar(context, content: Text(message));
    if (outcome.result == BbsPostResult.posted ||
        outcome.result == BbsPostResult.noReply) {
      await _sync(quiet: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<BbsSyncService?>()!;
    final readOnly = context.radioReadOnly;
    final syncing = service.isSyncing(_bbsKey);
    final posting = service.isPosting(_bbsKey);
    final categories = _board?.categories ?? const <BbsCategory>[];
    final title = AdaptiveAppBarTitle(
      context.l10n.bbs_title(widget.contact.name),
    );
    final refresh = IconButton(
      tooltip: context.l10n.bbs_sync,
      onPressed: readOnly || syncing || posting
          ? null
          : () => unawaited(_sync()),
      icon: syncing || posting
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
        floatingActionButton: readOnly
            ? null
            : Builder(
                builder: (context) => FloatingActionButton.extended(
                  tooltip: context.l10n.bbs_postTitle,
                  onPressed: syncing || posting
                      ? null
                      : () {
                          // The category of the open tab; the All tab
                          // starts with the first category.
                          final tab = DefaultTabController.of(context).index;
                          unawaited(_post(categories[tab == 0 ? 0 : tab - 1]));
                        },
                  icon: const Icon(Icons.edit_outlined),
                  label: Text(context.l10n.bbs_post),
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
          // Room for the Post button below the last message.
          padding: EdgeInsets.only(bottom: readOnly ? 16 : 88),
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

/// Category choice and text for one `!p`. Returns the chosen category and
/// the text, or `null` when cancelled.
class _BbsPostDialog extends StatefulWidget {
  const _BbsPostDialog({required this.categories, required this.initial});

  final List<BbsCategory> categories;
  final BbsCategory initial;

  @override
  State<_BbsPostDialog> createState() => _BbsPostDialogState();
}

class _BbsPostDialogState extends State<_BbsPostDialog> {
  late BbsCategory _category = widget.initial;
  final TextEditingController _text = TextEditingController();

  /// Bytes the whole `!p` command takes in one DM.
  int _bytes(String text) => utf8
      .encode(
        BbsProtocol.postCommand(
          _category.abbreviation,
          BbsSyncService.postText(text),
        ),
      )
      .length;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final limit = maxContactMessageBytes();
    final text = _text.text;
    final used = _bytes(text);
    final canPost = BbsSyncService.postText(text).isNotEmpty && used <= limit;
    return AlertDialog(
      title: Text(context.l10n.bbs_postTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<BbsCategory>(
              initialValue: _category,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: context.l10n.bbs_postCategory,
              ),
              items: [
                for (final category in widget.categories)
                  DropdownMenuItem(
                    value: category,
                    child: Text(category.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _category = value);
              },
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _text,
              autofocus: true,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(
                labelText: context.l10n.bbs_postMessage,
                counterText: '$used / $limit',
              ),
              inputFormatters: [
                Utf8LengthLimitingTextInputFormatter(
                  limit,
                  encoder: (value) => BbsProtocol.postCommand(
                    _category.abbreviation,
                    BbsSyncService.postText(value),
                  ),
                ),
              ],
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.common_cancel),
        ),
        FilledButton(
          onPressed: canPost
              ? () => Navigator.pop(context, (_category, text))
              : null,
          child: Text(context.l10n.bbs_post),
        ),
      ],
    );
  }
}
