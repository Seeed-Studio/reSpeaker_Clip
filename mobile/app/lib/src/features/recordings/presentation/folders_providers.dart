import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/folders_repository.dart';
import '../domain/folder.dart';

final foldersListProvider = FutureProvider<List<Folder>>((ref) async {
  final repo = await ref.watch(foldersRepositoryProvider.future);
  return repo.listAll();
});

