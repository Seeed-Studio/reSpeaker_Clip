import 'ai_providers.dart';

class SttConfig {
  final String id;
  final SttProvider provider;
  final String name;
  final String apiKey;
  final String? apiSecret;
  final String? appId;
  final String? accessKeyId;
  final String? accessKeySecret;
  final String? region;
  final String? baseUrl;
  final String? language;
  final String? modelName;
  final String? modelPath;
  final String? extraJson;
  final int sortIndex;
  final DateTime createdAt;
  final DateTime updatedAt;

  const SttConfig({
    required this.id,
    required this.provider,
    required this.name,
    required this.apiKey,
    this.apiSecret,
    this.appId,
    this.accessKeyId,
    this.accessKeySecret,
    this.region,
    this.baseUrl,
    this.language,
    this.modelName,
    this.modelPath,
    this.extraJson,
    required this.sortIndex,
    required this.createdAt,
    required this.updatedAt,
  });

  SttConfig copyWith({
    String? id,
    SttProvider? provider,
    String? name,
    String? apiKey,
    String? apiSecret,
    String? appId,
    String? accessKeyId,
    String? accessKeySecret,
    String? region,
    String? baseUrl,
    String? language,
    String? modelName,
    String? modelPath,
    String? extraJson,
    int? sortIndex,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return SttConfig(
      id: id ?? this.id,
      provider: provider ?? this.provider,
      name: name ?? this.name,
      apiKey: apiKey ?? this.apiKey,
      apiSecret: apiSecret ?? this.apiSecret,
      appId: appId ?? this.appId,
      accessKeyId: accessKeyId ?? this.accessKeyId,
      accessKeySecret: accessKeySecret ?? this.accessKeySecret,
      region: region ?? this.region,
      baseUrl: baseUrl ?? this.baseUrl,
      language: language ?? this.language,
      modelName: modelName ?? this.modelName,
      modelPath: modelPath ?? this.modelPath,
      extraJson: extraJson ?? this.extraJson,
      sortIndex: sortIndex ?? this.sortIndex,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

