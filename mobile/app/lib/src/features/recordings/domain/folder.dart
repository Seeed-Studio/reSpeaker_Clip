import 'package:flutter/material.dart';

class Folder {
  final String id;
  final String name;
  /// ARGB int
  final int color;
  /// Material icon codePoint
  final int icon;
  final int sortIndex;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Folder({
    required this.id,
    required this.name,
    required this.color,
    required this.icon,
    required this.sortIndex,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Allowed folder icons (must be const for tree-shake). Matches _CreateFolderSheet.
  static const _allowedIcons = <IconData>[
    Icons.folder,
    Icons.work_outline,
    Icons.favorite_border,
    Icons.menu_book_outlined,
    Icons.lightbulb_outline,
    Icons.home_outlined,
    Icons.music_note_outlined,
    Icons.fitness_center_outlined,
    Icons.flight_takeoff_outlined,
  ];

  IconData get iconData {
    for (final id in _allowedIcons) {
      if (id.codePoint == icon) return id;
    }
    return _allowedIcons.first;
  }

  Color get colorValue => Color(color);
}

