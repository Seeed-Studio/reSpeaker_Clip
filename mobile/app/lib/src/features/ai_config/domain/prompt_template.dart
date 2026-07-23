class PromptTemplate {
  final String id;
  final int? remoteId;
  final String name;
  final String prompt;
  final bool isDefault;
  final String? shareKey;
  /// True if imported via share key in this session (hide share action).
  /// Not persisted server-side; may reset after a full list refresh.
  final bool isImported;
  final int iconCode; // Material icon codePoint (UI-only; not synced)
  final int sortIndex;
  final DateTime createdAt;
  final DateTime updatedAt;

  const PromptTemplate({
    required this.id,
    this.remoteId,
    required this.name,
    required this.prompt,
    required this.isDefault,
    this.shareKey,
    this.isImported = false,
    required this.iconCode,
    required this.sortIndex,
    required this.createdAt,
    required this.updatedAt,
  });

  static String idForRemote(int remoteId) => 'tpl_$remoteId';

  /// Resolve a previously stored selection id (including legacy local `tpl-*`).
  static PromptTemplate? resolveStoredId(
    List<PromptTemplate> list,
    String? stored,
  ) {
    final raw = stored?.trim() ?? '';
    if (raw.isEmpty || list.isEmpty) return null;
    for (final t in list) {
      if (t.id == raw) return t;
    }
    if (raw.startsWith('tpl_')) {
      final n = int.tryParse(raw.substring(4));
      if (n != null) {
        for (final t in list) {
          if (t.remoteId == n) return t;
        }
      }
    }
    final asInt = int.tryParse(raw);
    if (asInt != null) {
      for (final t in list) {
        if (t.remoteId == asInt) return t;
      }
    }
    return null;
  }

  PromptTemplate copyWith({
    String? id,
    int? remoteId,
    String? name,
    String? prompt,
    bool? isDefault,
    String? shareKey,
    bool? isImported,
    int? iconCode,
    int? sortIndex,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return PromptTemplate(
      id: id ?? this.id,
      remoteId: remoteId ?? this.remoteId,
      name: name ?? this.name,
      prompt: prompt ?? this.prompt,
      isDefault: isDefault ?? this.isDefault,
      shareKey: shareKey ?? this.shareKey,
      isImported: isImported ?? this.isImported,
      iconCode: iconCode ?? this.iconCode,
      sortIndex: sortIndex ?? this.sortIndex,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
