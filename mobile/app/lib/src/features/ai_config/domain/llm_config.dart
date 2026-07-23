import 'ai_providers.dart';

class LlmConfig {
  final String id;
  final LlmProvider provider;
  final String name;
  final String apiKey;
  final String? apiSecret;
  final String? appId;
  final String? accessKeyId;
  final String? accessKeySecret;
  final String? region;
  final String? baseUrl;
  final String? modelName;
  final String? moduleName;
  final String? extraJson;
  final int sortIndex;
  final DateTime createdAt;
  final DateTime updatedAt;

  const LlmConfig({
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
    this.modelName,
    this.moduleName,
    this.extraJson,
    required this.sortIndex,
    required this.createdAt,
    required this.updatedAt,
  });

  LlmConfig copyWith({
    String? id,
    LlmProvider? provider,
    String? name,
    String? apiKey,
    String? apiSecret,
    String? appId,
    String? accessKeyId,
    String? accessKeySecret,
    String? region,
    String? baseUrl,
    String? modelName,
    String? moduleName,
    String? extraJson,
    int? sortIndex,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return LlmConfig(
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
      modelName: modelName ?? this.modelName,
      moduleName: moduleName ?? this.moduleName,
      extraJson: extraJson ?? this.extraJson,
      sortIndex: sortIndex ?? this.sortIndex,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

