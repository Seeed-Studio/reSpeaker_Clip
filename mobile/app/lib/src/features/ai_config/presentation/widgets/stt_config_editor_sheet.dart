import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_radii.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/server/server_error_localizer.dart';
import '../../../../core/server/server_exception.dart';
import '../../../../core/widgets/app_bottom_sheet.dart';
import '../../../../core/widgets/app_overlay_tap_dismiss.dart';
import '../../../../core/widgets/app_pill_button.dart';
import '../../../../core/widgets/app_dialogs.dart';
import '../../data/asr_config_repository.dart';
import '../../domain/ai_providers.dart';
import '../../domain/asr_vendor_config.dart';
import '../../domain/stt_config.dart';
import 'ai_config_validation.dart';
import 'ai_config_field_caption.dart';

Future<void> showSttConfigEditorSheet(
  BuildContext context, {
  SttConfig? existing,
}) async {
  await showAppBottomSheet<void>(
    context,
    builder: (_) =>
        _SheetScrollWrapper(child: SttConfigEditorSheet(existing: existing)),
  );
}

class SttConfigEditorSheet extends ConsumerStatefulWidget {
  final SttConfig? existing;
  const SttConfigEditorSheet({super.key, required this.existing});

  @override
  ConsumerState<SttConfigEditorSheet> createState() =>
      _SttConfigEditorSheetState();
}

class _SttConfigEditorSheetState extends ConsumerState<SttConfigEditorSheet> {
  late SttProvider _provider;
  late final TextEditingController _name;
  late final TextEditingController _apiKey;
  late final TextEditingController _apiSecret;
  late final TextEditingController _appId;
  late final TextEditingController _accessKeyId;
  late final TextEditingController _accessKeySecret;
  late final TextEditingController _region;
  late final TextEditingController _baseUrl;
  late final TextEditingController _language;
  late final TextEditingController _modelName;
  late final TextEditingController _modelPath;
  late final TextEditingController _extraJson;
  // Doubao (ByteDance) ASR: required cluster + access_token in extra_json per docs
  late final TextEditingController _doubaoCluster;
  late final TextEditingController _doubaoAccessToken;

  bool _showKey = false;
  bool _testedOk = false;
  bool _testingConnection = false;
  String? _testMsg;
  final GlobalKey _providerFieldKey = GlobalKey();
  bool _showAdvanced = false;
  bool _showProviderList = false;
  static const List<String> _kLangOptions = ['Auto', 'zh', 'en'];
  // iFlytek: file = offline file ASR (recommended) | realtime = live
  String _iflytekMode = 'file';
  bool _showIflytekModeList = false;
  bool _didApplyDefaultLocalizedName = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _provider = e?.provider ?? SttProvider.openAiWhisper;
    _name = TextEditingController(text: e?.name ?? '${_provider.label} API');
    _apiKey = TextEditingController(text: e?.apiKey ?? '');
    _apiSecret = TextEditingController(text: e?.apiSecret ?? '');
    _appId = TextEditingController(text: e?.appId ?? '');
    _accessKeyId = TextEditingController(text: e?.accessKeyId ?? '');
    _accessKeySecret = TextEditingController(text: e?.accessKeySecret ?? '');
    _region = TextEditingController(text: e?.region ?? '');
    _baseUrl =
        TextEditingController(text: e?.baseUrl ?? _provider.defaultBaseUrl);
    _language = TextEditingController(text: e?.language ?? 'Auto');
    // Model: default from server if empty; iFlytek `model` selects ASR mode
    final modelVal = (e?.modelName ?? '').trim();
    final defaultModel = _provider.defaultAsrModel;
    _modelName = TextEditingController(
        text: modelVal.isNotEmpty
            ? modelVal
            : (defaultModel.isNotEmpty ? defaultModel : ''));
    // iFlytek: init mode from model, default file ASR
    if (_provider == SttProvider.iflytek && e != null) {
      final m = (e.modelName ?? '').trim().toLowerCase();
      if (m == 'realtime' || m == 'rtasr') {
        _iflytekMode = 'realtime';
      } else if (m == 'file' || m == 'lfasr' || m == 'standard') {
        _iflytekMode = 'file';
      }
    }
    _modelPath = TextEditingController(text: e?.modelPath ?? '');
    _extraJson = TextEditingController(text: e?.extraJson ?? '');

    // Do not show Aliyun ws_url in UI; keep empty so 'wss://' placeholders are not
    // sent. Backend expects full ws/wss URLs only.

    // Pre-fill Doubao cluster/access_token from extra_json
    String cluster = '';
    String token = '';
    final raw = (e?.extraJson ?? '').trim();
    if (raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          cluster = (decoded['cluster'] ?? '').toString();
          token = (decoded['access_token'] ?? '').toString();
        }
      } catch (_) {
        // ignore
      }
    }
    _doubaoCluster = TextEditingController(text: cluster);
    _doubaoAccessToken = TextEditingController(text: token);
    for (final c in _connectionTestControllers) {
      c.addListener(_invalidateConnectionTest);
    }
  }

  List<TextEditingController> get _connectionTestControllers => [
        _name,
        _apiKey,
        _apiSecret,
        _appId,
        _accessKeyId,
        _accessKeySecret,
        _region,
        _baseUrl,
        _language,
        _modelName,
        _modelPath,
        _extraJson,
        _doubaoCluster,
        _doubaoAccessToken,
      ];

  void _invalidateConnectionTest() {
    if (!_testedOk && _testMsg == null) return;
    setState(() {
      _testedOk = false;
      _testMsg = null;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didApplyDefaultLocalizedName) return;
    _didApplyDefaultLocalizedName = true;
    if (widget.existing != null) return;
    final l10n = AppLocalizations.of(context)!;
    _name.text = '${_provider.labelFor(l10n)} API';
  }

  String _sttLangPickerRowLabel(String opt, AppLocalizations l10n) {
    if (opt == 'Auto') return l10n.auto;
    return opt;
  }

  String _sttLangFieldCaption(AppLocalizations l10n) {
    final t = _language.text.trim();
    if (t.isEmpty || t == 'Auto') return l10n.auto;
    return t;
  }

  @override
  void dispose() {
    for (final c in _connectionTestControllers) {
      c.removeListener(_invalidateConnectionTest);
    }
    _name.dispose();
    _apiKey.dispose();
    _apiSecret.dispose();
    _appId.dispose();
    _accessKeyId.dispose();
    _accessKeySecret.dispose();
    _region.dispose();
    _baseUrl.dispose();
    _language.dispose();
    _modelName.dispose();
    _modelPath.dispose();
    _extraJson.dispose();
    _doubaoCluster.dispose();
    _doubaoAccessToken.dispose();
    super.dispose();
  }

  List<SttProvider> _preferredSttProviders({SttProvider? include}) {
    // Server STT + offline STT rows in table order
    final list = <SttProvider>[
      SttProvider.openAiWhisper,
      SttProvider.googleGemini,
      SttProvider.deepgram,
      SttProvider.vosk,
      SttProvider.iflytek,
      SttProvider.tencent,
      SttProvider.aliyun,
      SttProvider.baidu,
      SttProvider.localWhisper,
      SttProvider.funasr,
      SttProvider.doubao,
    ];
    if (include != null && !list.contains(include)) list.add(include);
    return list;
  }

  InputDecoration _secretDeco(Color primary, {String? hintText}) {
    return InputDecoration(
      hintText: hintText,
      isDense: true,
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.r18),
        borderSide: const BorderSide(color: AppColors.borderLight),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.r18),
        borderSide: const BorderSide(color: AppColors.borderLight),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.r18),
        borderSide: BorderSide(color: primary, width: 1.5),
      ),
      suffixIcon: IconButton(
        onPressed: () => setState(() => _showKey = !_showKey),
        icon: Icon(_showKey ? Icons.visibility_off : Icons.visibility),
      ),
    );
  }

  String _buildExtraJsonForSave() {
    if (_provider != SttProvider.doubao) return _extraJson.text.trim();
    // Doubao required fields go to extra_json object
    Map<String, dynamic> m = <String, dynamic>{};
    final raw = _extraJson.text.trim();
    if (raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          m = decoded.map((k, v) => MapEntry(k.toString(), v));
        }
      } catch (_) {
        m = <String, dynamic>{};
      }
    }
    // Keep server vendor id for update/delete
    final remoteId = m['_remote_id'];
    m['cluster'] = _doubaoCluster.text.trim();
    m['access_token'] = _doubaoAccessToken.text.trim();
    if (remoteId != null) {
      m['_remote_id'] = remoteId;
    }
    return jsonEncode(m);
  }

  String? _validateInputs() {
    final l10n = AppLocalizations.of(context)!;
    return validateSttInputs(
      provider: _provider,
      name: _name.text,
      apiKey: _apiKey.text,
      apiSecret: _apiSecret.text,
      appId: _appId.text,
      accessKeyId: _accessKeyId.text,
      accessKeySecret: _accessKeySecret.text,
      region: _region.text,
      baseUrl: _baseUrl.text,
      modelName:
          _provider == SttProvider.iflytek ? _iflytekMode : _modelName.text,
      modelPath: _modelPath.text,
      extraJson: _buildExtraJsonForSave(),
      l10n: l10n,
    );
  }

  String? _validateConnectionTest() {
    final l10n = AppLocalizations.of(context)!;
    return validateSttConnectionTest(
      provider: _provider,
      name: _name.text,
      apiKey: _apiKey.text,
      apiSecret: _apiSecret.text,
      appId: _appId.text,
      accessKeyId: _accessKeyId.text,
      accessKeySecret: _accessKeySecret.text,
      region: _region.text,
      baseUrl: _baseUrl.text,
      modelName:
          _provider == SttProvider.iflytek ? _iflytekMode : _modelName.text,
      modelPath: _modelPath.text,
      extraJson: _buildExtraJsonForSave(),
      l10n: l10n,
    );
  }

  String? _modelNameForSave() {
    if (_provider == SttProvider.iflytek) {
      return _iflytekMode;
    }
    final raw = _modelName.text.trim();
    final model = raw.isEmpty
        ? (_provider.defaultAsrModel.isEmpty ? null : _provider.defaultAsrModel)
        : raw;
    if (model == null) return null;
    if (_provider == SttProvider.googleGemini) {
      return normalizeGeminiModelNameInput(model);
    }
    return model;
  }

  SttConfig _buildDraftConfig(AsrConfigRepository asrRepo) {
    final name = _name.text.trim();
    final key = _apiKey.text.trim();
    final extra = _buildExtraJsonForSave();
    return asrRepo.buildConfigForCreate(
      provider: _provider,
      name: name,
      apiKey: key,
      apiSecret: _apiSecret.text.trim().isEmpty ? null : _apiSecret.text.trim(),
      appId: _appId.text.trim().isEmpty ? null : _appId.text.trim(),
      accessKeyId:
          _accessKeyId.text.trim().isEmpty ? null : _accessKeyId.text.trim(),
      accessKeySecret: _accessKeySecret.text.trim().isEmpty
          ? null
          : _accessKeySecret.text.trim(),
      region: _region.text.trim().isEmpty ? null : _region.text.trim(),
      baseUrl: _baseUrl.text.trim().isEmpty ? null : _baseUrl.text.trim(),
      language: _language.text.trim().isEmpty ? null : _language.text.trim(),
      modelName: _modelNameForSave(),
      modelPath:
          _modelPath.text.trim().isEmpty ? null : _modelPath.text.trim(),
      extraJson: extra.isEmpty ? null : extra,
    );
  }

  void _applyProvider(SttProvider picked, AppLocalizations l10n) {
    setState(() {
      _provider = picked;
      _showIflytekModeList = false;
      _apiKey.text = '';
      _apiSecret.text = '';
      _appId.text = '';
      _accessKeyId.text = '';
      _accessKeySecret.text = '';
      _region.text = '';
      _modelName.text = _provider.defaultAsrModel;
      _modelPath.text = '';
      _extraJson.text = '';
      _doubaoCluster.text = '';
      _doubaoAccessToken.text = '';
      _language.text = 'Auto';
      if (_name.text.trim().isEmpty || _name.text.endsWith('API')) {
        _name.text = '${_provider.labelFor(l10n)} API';
      }
      _baseUrl.text = _provider.defaultBaseUrl;
      _testedOk = false;
      _testMsg = null;
      _testingConnection = false;
      _showProviderList = false;
    });
  }

  Widget _buildIflytekModeList(Color primary, AppLocalizations l10n) {
    final options = [
      ('file', l10n.iflytekModeFile),
      ('realtime', l10n.iflytekModeRealtime),
    ];
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.r18),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(
        children: [
          for (var i = 0; i < options.length; i++) ...[
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => setState(() {
                  _iflytekMode = options[i].$1;
                  _showIflytekModeList = false;
                  _testedOk = false;
                  _testMsg = null;
                }),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(i == 0 ? AppRadii.r18 : 0),
                  topRight: Radius.circular(i == 0 ? AppRadii.r18 : 0),
                  bottomLeft: Radius.circular(
                      i == options.length - 1 ? AppRadii.r18 : 0),
                  bottomRight: Radius.circular(
                      i == options.length - 1 ? AppRadii.r18 : 0),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          options[i].$2,
                          style: const TextStyle(
                            fontSize: AppTypography.s14,
                            fontWeight: FontWeight.w500,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      if (_iflytekMode == options[i].$1)
                        Icon(Icons.check_circle, size: 18, color: primary),
                    ],
                  ),
                ),
              ),
            ),
            if (i != options.length - 1)
              const Divider(height: 1, color: AppColors.borderLight),
          ],
        ],
      ),
    );
  }

  Widget _buildProviderList(BuildContext context, AppLocalizations l10n) {
    final providers =
        _preferredSttProviders(include: widget.existing?.provider);
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.r18),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(
        children: [
          for (var i = 0; i < providers.length; i++) ...[
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => _applyProvider(providers[i], l10n),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(i == 0 ? AppRadii.r18 : 0),
                  topRight: Radius.circular(i == 0 ? AppRadii.r18 : 0),
                  bottomLeft: Radius.circular(
                      i == providers.length - 1 ? AppRadii.r18 : 0),
                  bottomRight: Radius.circular(
                      i == providers.length - 1 ? AppRadii.r18 : 0),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          providers[i].labelFor(l10n),
                          style: const TextStyle(
                            fontSize: AppTypography.s14,
                            fontWeight: FontWeight.w500,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      if (providers[i] == _provider)
                        Icon(Icons.check_circle,
                            size: 18,
                            color: Theme.of(context).colorScheme.primary),
                    ],
                  ),
                ),
              ),
            ),
            if (i != providers.length - 1)
              const Divider(height: 1, color: AppColors.borderLight),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final l10n = AppLocalizations.of(context)!;
    final isEdit = widget.existing != null;

    InputDecoration inputDeco({String? hintText, Widget? suffixIcon}) {
      return InputDecoration(
        hintText: hintText,
        isDense: true,
        filled: true,
        fillColor: AppColors.surface,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.r18),
          borderSide: const BorderSide(color: AppColors.borderLight),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.r18),
          borderSide: const BorderSide(color: AppColors.borderLight),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.r18),
          borderSide: BorderSide(color: primary, width: 1.5),
        ),
        suffixIcon: suffixIcon,
      );
    }

    Future<void> pickLanguage(BuildContext anchorContext) async {
      final overlay = Overlay.of(anchorContext);
      final box = anchorContext.findRenderObject() as RenderBox?;
      final ovBox = overlay.context.findRenderObject() as RenderBox?;
      if (box == null || ovBox == null) return;

      final topLeft = box.localToGlobal(Offset.zero, ancestor: ovBox);
      final size = box.size;
      final screenW = ovBox.size.width;
      final screenH = ovBox.size.height;

      const margin = 24.0;
      const gap = 8.0;
      const maxH = 320.0;
      const minH = 180.0;

      final left = margin;
      final width = (screenW - margin * 2).clamp(240.0, screenW);

      final belowTop = topLeft.dy + size.height + gap;
      final availableBelow = screenH - margin - belowTop;
      final availableAbove = topLeft.dy - margin - gap;

      final itemH = 52.0;
      final desired = (56 + 1 + 12 + _kLangOptions.length * itemH)
          .toDouble()
          .clamp(minH, maxH);
      final placeBelow =
          availableBelow >= minH || availableBelow >= availableAbove;
      final height =
          (placeBelow ? availableBelow : availableAbove).clamp(160.0, desired);
      final top = placeBelow ? belowTop : (topLeft.dy - gap - height);

      final completer = Completer<String?>();
      late OverlayEntry entry;
      void dismiss([String? v]) {
        if (entry.mounted) entry.remove();
        if (!completer.isCompleted) completer.complete(v);
      }

      entry = OverlayEntry(
        builder: (ctx) {
          return AppOverlayTapDismiss(
            onDismiss: () => dismiss(null),
            child: Positioned(
              left: left,
              top: top,
              child: Material(
                color: Colors.transparent,
                elevation: 12,
                borderRadius: BorderRadius.circular(AppRadii.r18),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.r18),
                  child: Container(
                    width: width,
                    height: height,
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(AppRadii.r18),
                      border: Border.all(color: AppColors.borderLight),
                    ),
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                          child: Stack(
                            children: [
                              Align(
                                alignment: Alignment.center,
                                child: Text(
                                  l10n.language,
                                  style: Theme.of(ctx)
                                      .textTheme
                                      .titleLarge
                                      ?.copyWith(
                                        fontWeight: FontWeight.w600,
                                        fontSize: AppTypography.s18,
                                        color: AppColors.textPrimary,
                                      ),
                                ),
                              ),
                              Align(
                                alignment: Alignment.centerRight,
                                child: InkWell(
                                  onTap: () => dismiss(null),
                                  borderRadius: BorderRadius.circular(999),
                                  child: Container(
                                    width: 32,
                                    height: 32,
                                    decoration: BoxDecoration(
                                      color: AppColors.surfaceMuted,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                          color: AppColors.borderLight),
                                    ),
                                    child: const Icon(Icons.close,
                                        size: 18,
                                        color: AppColors.textSecondary),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Divider(
                            height: 1,
                            thickness: 1,
                            color: AppColors.borderLight),
                        Expanded(
                          child: ListView.separated(
                            padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
                            itemCount: _kLangOptions.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (c, i) {
                              final opt = _kLangOptions[i];
                              final selected = opt == _language.text.trim();
                              return InkWell(
                                onTap: () => dismiss(opt),
                                borderRadius:
                                    BorderRadius.circular(AppRadii.r18),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 14),
                                  decoration: BoxDecoration(
                                    color: selected
                                        ? AppColors.surfacePrimarySoft
                                        : AppColors.surface,
                                    borderRadius:
                                        BorderRadius.circular(AppRadii.r18),
                                    border: Border.all(
                                      color: selected
                                          ? primary.withValues(alpha: 0.22)
                                          : AppColors.borderLight,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          _sttLangPickerRowLabel(opt, l10n),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: AppTypography.s14,
                                            fontWeight: FontWeight.w600,
                                            color: selected
                                                ? primary
                                                : AppColors.textPrimary,
                                          ),
                                        ),
                                      ),
                                      if (selected)
                                        Icon(Icons.check, color: primary),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );

      overlay.insert(entry);
      final picked = await completer.future;
      if (picked == null) return;
      if (!mounted) return;
      setState(() {
        _language.text = picked;
        _testedOk = false;
        _testMsg = null;
      });
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.apiKeyConfigDetails,
                  style: const TextStyle(
                    fontSize: AppTypography.s18,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: const Icon(Icons.close,
                    size: 22, color: AppColors.textSecondary),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.only(top: 12, bottom: 4),
            child: Divider(height: 1, color: AppColors.borderLight),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _FieldLabel(l10n.fieldLabelProvider),
              InkWell(
                onTap: () =>
                    setState(() => _showProviderList = !_showProviderList),
                borderRadius: BorderRadius.circular(AppRadii.r18),
                child: InputDecorator(
                  key: _providerFieldKey,
                  decoration: inputDeco(
                    suffixIcon: Icon(
                      _showProviderList ? Icons.expand_less : Icons.expand_more,
                      color: AppColors.textPlaceholder,
                    ),
                  ),
                  child: Text(
                    _provider.labelFor(l10n),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: AppTypography.s14,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
              ),
              if (_showProviderList) ...[
                const SizedBox(height: 8),
                _buildProviderList(context, l10n),
              ],
              const SizedBox(height: 12),
              _FieldLabel(l10n.fieldLabelName),
              TextField(
                  controller: _name,
                  textAlignVertical: TextAlignVertical.center,
                  decoration: inputDeco()),
              const SizedBox(height: 12),
              ..._buildProviderSpecificFields(primary, inputDeco, l10n),
              _FieldLabel(l10n.fieldLabelLanguage),
              InkWell(
                onTap: () async {
                  final anchorCtx = _providerFieldKey.currentContext;
                  if (anchorCtx == null) return;
                  await pickLanguage(anchorCtx);
                },
                borderRadius: BorderRadius.circular(AppRadii.r18),
                child: InputDecorator(
                  decoration: inputDeco(
                    suffixIcon: const Icon(Icons.expand_more,
                        color: AppColors.textPlaceholder),
                  ),
                  child: Text(
                    _sttLangFieldCaption(l10n),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: AppTypography.s14,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
              ),
              // Model Name only for providers whose config_json accepts `model`;
              // others (funasr/openAiWhisper/deepgram/vosk/localWhisper/
              // tencent/baidu/doubao) would ignore it — hide to avoid confusion.
              // iflytek uses transcription mode instead of model.
              if (_provider == SttProvider.aliyun ||
                  _provider == SttProvider.googleGemini) ...[
                const SizedBox(height: 12),
                _FieldLabel(l10n.fieldLabelModelNameOptional),
                TextField(
                  controller: _modelName,
                  textAlignVertical: TextAlignVertical.center,
                  decoration:
                      inputDeco(hintText: _provider.sttModelNameHint(l10n)),
                ),
                AiConfigFieldCaption(_provider.sttModelFieldCaption(l10n)),
              ],
              const SizedBox(height: 12),
              InkWell(
                onTap: () => setState(() => _showAdvanced = !_showAdvanced),
                child: Row(
                  children: [
                    Icon(_showAdvanced ? Icons.expand_less : Icons.expand_more,
                        color: AppColors.textPlaceholder),
                    const SizedBox(width: 6),
                    Text(
                      l10n.advancedLabel,
                      style: const TextStyle(
                          color: AppColors.textPlaceholder,
                          fontWeight: FontWeight.w600,
                          fontSize: AppTypography.s14),
                    ),
                  ],
                ),
              ),
              if (_showAdvanced) ...[
                const SizedBox(height: 12),
                _FieldLabel(l10n.fieldLabelExtraJsonAdvanced),
                TextField(
                  controller: _extraJson,
                  textAlignVertical: TextAlignVertical.center,
                  minLines: 3,
                  maxLines: 6,
                  decoration: inputDeco(hintText: l10n.hintJsonExample),
                ),
              ],
              const Padding(
                padding: EdgeInsets.only(top: 16, bottom: 12),
                child: Divider(height: 1, color: AppColors.borderLight),
              ),
              InkWell(
                onTap: _testingConnection ? null : () => unawaited(_testConnection()),
                borderRadius: BorderRadius.circular(AppRadii.r8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Builder(
                    builder: (context) {
                      final testFailed = !_testingConnection &&
                          !_testedOk &&
                          _testMsg != null;
                      final testColor =
                          testFailed ? AppColors.danger : primary;
                      Widget? leading;
                      if (_testingConnection) {
                        leading = SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: primary,
                          ),
                        );
                      } else if (_testedOk) {
                        leading = Icon(
                          Icons.check_circle,
                          size: 20,
                          color: testColor,
                        );
                      } else if (testFailed) {
                        leading = Icon(
                          Icons.error_outline,
                          size: 20,
                          color: testColor,
                        );
                      }
                      return Row(
                        children: [
                          if (leading != null) ...[
                            leading,
                            const SizedBox(width: 10),
                          ],
                          Expanded(
                            child: Text(
                              _testMsg ??
                                  (_testingConnection
                                      ? l10n.processing
                                      : l10n.testConnection),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: testColor,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              AppBlackPillButton(
                label: isEdit
                    ? l10n.updateConfigurationLabel
                    : l10n.saveConfiguration,
                onPressed: () => _save(isEdit),
              ),
              if (isEdit) ...[
                const SizedBox(height: 10),
                TextButton(
                  onPressed: _delete,
                  child: Text(
                    l10n.delete,
                    style: const TextStyle(
                        color: AppColors.danger,
                        fontWeight: FontWeight.w500,
                        fontSize: AppTypography.s14),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _buildProviderSpecificFields(
      Color primary,
      InputDecoration Function({String? hintText, Widget? suffixIcon})
          inputDeco,
      AppLocalizations l10n) {
    final widgets = <Widget>[];

    // -------------------- Server STT (docx/ASR vendor spec PDF) --------------------
    if (_provider == SttProvider.aliyun) {
      widgets.addAll([
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: AppColors.surfaceMuted,
            borderRadius: BorderRadius.circular(AppRadii.r12),
            border: Border.all(color: AppColors.borderLight),
          ),
          child: Text(
            l10n.aliyunCredentialChoiceHint,
            style: const TextStyle(
              fontSize: AppTypography.s12,
              color: AppColors.textSecondary,
              height: 1.4,
            ),
          ),
        ),
        _FieldLabel(l10n.fieldLabelAliyunApiKeyChoice),
        TextField(
            controller: _apiKey,
            obscureText: !_showKey,
            textAlignVertical: TextAlignVertical.center,
            decoration: _secretDeco(primary)),
        const SizedBox(height: 12),
        _FieldLabel(l10n.fieldLabelAliyunAppKeyChoice),
        TextField(
          controller: _appId,
          textAlignVertical: TextAlignVertical.center,
          decoration: inputDeco(hintText: l10n.hintAliyunTingwuAppKey),
        ),
        const SizedBox(height: 12),
        _FieldLabel(l10n.fieldLabelAliyunAccessKeyIdChoice),
        TextField(
          controller: _accessKeyId,
          textAlignVertical: TextAlignVertical.center,
          decoration: inputDeco(hintText: l10n.hintAliyunAccessKeyId),
        ),
        const SizedBox(height: 12),
        _FieldLabel(l10n.fieldLabelAliyunAccessKeySecretChoice),
        TextField(
          controller: _accessKeySecret,
          obscureText: !_showKey,
          textAlignVertical: TextAlignVertical.center,
          decoration:
              _secretDeco(primary, hintText: l10n.hintAliyunAccessKeySecret),
        ),
        const SizedBox(height: 12),
        _FieldLabel(l10n.fieldLabelRegionOptional),
        TextField(
          controller: _region,
          textAlignVertical: TextAlignVertical.center,
          decoration: inputDeco(hintText: l10n.hintRegionExample),
        ),
        const SizedBox(height: 12),
      ]);
      return widgets;
    }

    if (_provider == SttProvider.funasr) {
      widgets.addAll([
        _FieldLabel(l10n.fieldLabelBaseUrlRequired),
        TextField(
            controller: _baseUrl,
            textAlignVertical: TextAlignVertical.center,
            decoration: inputDeco(hintText: l10n.hintBaseUrlExample)),
        const SizedBox(height: 12),
        _FieldLabel(l10n.fieldLabelApiKeyOptional),
        TextField(
            controller: _apiKey,
            obscureText: !_showKey,
            textAlignVertical: TextAlignVertical.center,
            decoration: _secretDeco(primary)),
        const SizedBox(height: 12),
      ]);
      return widgets;
    }

    if (_provider == SttProvider.openAiWhisper) {
      widgets.addAll([
        _FieldLabel(l10n.fieldLabelBaseUrlOptional),
        TextField(
            controller: _baseUrl,
            textAlignVertical: TextAlignVertical.center,
            decoration: inputDeco(hintText: l10n.hintBaseUrlExampleHttps)),
        const SizedBox(height: 12),
        _FieldLabel(l10n.fieldLabelApiKeyOptional),
        TextField(
            controller: _apiKey,
            obscureText: !_showKey,
            textAlignVertical: TextAlignVertical.center,
            decoration: _secretDeco(primary)),
        const SizedBox(height: 12),
      ]);
      return widgets;
    }

    if (_provider == SttProvider.deepgram) {
      widgets.addAll([
        _FieldLabel(l10n.fieldLabelApiKeyRequired),
        TextField(
            controller: _apiKey,
            obscureText: !_showKey,
            textAlignVertical: TextAlignVertical.center,
            decoration: _secretDeco(primary)),
        const SizedBox(height: 12),
      ]);
      return widgets;
    }

    if (_provider == SttProvider.vosk) {
      widgets.addAll([
        _FieldLabel(l10n.fieldLabelBaseUrlRequired),
        TextField(
            controller: _baseUrl,
            textAlignVertical: TextAlignVertical.center,
            decoration: inputDeco(hintText: l10n.hintLocalhostVosk)),
        const SizedBox(height: 12),
      ]);
      return widgets;
    }

    if (_provider == SttProvider.localWhisper) {
      widgets.addAll([
        _FieldLabel(l10n.fieldLabelBaseUrlRequired),
        TextField(
            controller: _baseUrl,
            textAlignVertical: TextAlignVertical.center,
            decoration: inputDeco(hintText: l10n.hintLocalhostLocalWhisper)),
        const SizedBox(height: 12),
        _FieldLabel(l10n.fieldLabelApiKeyOptional),
        TextField(
            controller: _apiKey,
            obscureText: !_showKey,
            textAlignVertical: TextAlignVertical.center,
            decoration: _secretDeco(primary)),
        const SizedBox(height: 12),
      ]);
      return widgets;
    }

    if (_provider == SttProvider.googleGemini) {
      widgets.addAll([
        _FieldLabel(l10n.fieldLabelApiKeyRequired),
        TextField(
            controller: _apiKey,
            obscureText: !_showKey,
            textAlignVertical: TextAlignVertical.center,
            decoration: _secretDeco(primary)),
        const SizedBox(height: 12),
      ]);
      return widgets;
    }

    if (_provider == SttProvider.baidu) {
      widgets.addAll([
        _FieldLabel(l10n.fieldLabelAppIdRequired),
        TextField(
            controller: _appId,
            textAlignVertical: TextAlignVertical.center,
            decoration: inputDeco()),
        const SizedBox(height: 12),
        _FieldLabel(l10n.fieldLabelApiKeyRequired),
        TextField(
            controller: _apiKey,
            obscureText: !_showKey,
            textAlignVertical: TextAlignVertical.center,
            decoration: _secretDeco(primary)),
        const SizedBox(height: 12),
        _FieldLabel(l10n.fieldLabelSecretKeyRequired),
        TextField(
            controller: _apiSecret,
            obscureText: !_showKey,
            textAlignVertical: TextAlignVertical.center,
            decoration: _secretDeco(primary)),
        const SizedBox(height: 12),
      ]);
      return widgets;
    }

    if (_provider == SttProvider.tencent) {
      widgets.addAll([
        _FieldLabel(l10n.fieldLabelSecretIdRequired),
        TextField(
            controller: _accessKeyId,
            textAlignVertical: TextAlignVertical.center,
            decoration: inputDeco()),
        const SizedBox(height: 12),
        _FieldLabel(l10n.fieldLabelSecretKeyRequired),
        TextField(
            controller: _accessKeySecret,
            obscureText: !_showKey,
            textAlignVertical: TextAlignVertical.center,
            decoration: _secretDeco(primary)),
        const SizedBox(height: 12),
      ]);
      return widgets;
    }

    if (_provider == SttProvider.doubao) {
      widgets.addAll([
        _FieldLabel(l10n.fieldLabelAppIdRequired),
        TextField(
            controller: _appId,
            textAlignVertical: TextAlignVertical.center,
            decoration: inputDeco()),
        const SizedBox(height: 12),
        _FieldLabel(l10n.fieldLabelClusterRequired),
        TextField(
            controller: _doubaoCluster,
            textAlignVertical: TextAlignVertical.center,
            decoration: inputDeco()),
        const SizedBox(height: 12),
        _FieldLabel(l10n.fieldLabelAccessTokenRequired),
        TextField(
            controller: _doubaoAccessToken,
            obscureText: !_showKey,
            textAlignVertical: TextAlignVertical.center,
            decoration: _secretDeco(primary)),
        const SizedBox(height: 12),
      ]);
      return widgets;
    }

    if (_provider == SttProvider.iflytek) {
      widgets.addAll([
        _FieldLabel(l10n.fieldLabelTranscriptionMode),
        InkWell(
          onTap: () =>
              setState(() => _showIflytekModeList = !_showIflytekModeList),
          borderRadius: BorderRadius.circular(AppRadii.r18),
          child: InputDecorator(
            decoration: inputDeco(
              suffixIcon: Icon(
                _showIflytekModeList ? Icons.expand_less : Icons.expand_more,
                color: AppColors.textPlaceholder,
              ),
            ),
            child: Text(
              _iflytekMode == 'file'
                  ? l10n.iflytekModeFile
                  : l10n.iflytekModeRealtime,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: AppTypography.s14,
                fontWeight: FontWeight.w500,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ),
        if (_showIflytekModeList) ...[
          const SizedBox(height: 8),
          _buildIflytekModeList(primary, l10n),
        ],
        const SizedBox(height: 12),
        _FieldLabel(l10n.fieldLabelAppIdRequired),
        TextField(
            controller: _appId,
            textAlignVertical: TextAlignVertical.center,
            decoration: inputDeco(hintText: l10n.hintIflytekAppId)),
        const SizedBox(height: 12),
        if (_iflytekMode == 'file') ...[
          _FieldLabel(l10n.fieldLabelSecretKeyRequired),
          TextField(
              controller: _apiSecret,
              obscureText: !_showKey,
              textAlignVertical: TextAlignVertical.center,
              decoration: _secretDeco(primary, hintText: l10n.iflytekFileHint)),
        ] else ...[
          _FieldLabel(l10n.fieldLabelApiKeyRequired),
          TextField(
              controller: _apiKey,
              obscureText: !_showKey,
              textAlignVertical: TextAlignVertical.center,
              decoration:
                  _secretDeco(primary, hintText: l10n.iflytekRealtimeHint)),
        ],
        const SizedBox(height: 12),
      ]);
      return widgets;
    }

    // -------------------- Legacy providers (unchanged behavior) --------------------
    final isLocal = sttIsLocalProvider(_provider);
    final showBaseUrl = sttShowBaseUrl(_provider);
    final showApiKey = sttShowApiKey(_provider);

    if (isLocal && _provider == SttProvider.onDeviceLocalStt) {
      widgets.addAll([
        _FieldLabel(l10n.fieldLabelModelPath),
        TextField(
            controller: _modelPath,
            textAlignVertical: TextAlignVertical.center,
            decoration: inputDeco(hintText: l10n.hintModelPathExample)),
        const SizedBox(height: 12),
      ]);
    }

    if (showApiKey) {
      widgets.addAll([
        _FieldLabel(l10n.fieldLabelApiKey),
        TextField(
            controller: _apiKey,
            obscureText: !_showKey,
            textAlignVertical: TextAlignVertical.center,
            decoration: _secretDeco(primary)),
        const SizedBox(height: 12),
      ]);
    }

    if (showBaseUrl) {
      widgets.addAll([
        Row(
          children: [
            _FieldLabel(l10n.fieldLabelBaseUrl),
            const Spacer(),
            Text(
              l10n.optionalLabel,
              style: const TextStyle(
                  color: AppColors.textPlaceholder,
                  fontWeight: FontWeight.w500,
                  fontSize: AppTypography.s14),
            ),
          ],
        ),
        TextField(
            controller: _baseUrl,
            textAlignVertical: TextAlignVertical.center,
            decoration: inputDeco()),
        const SizedBox(height: 12),
      ]);
    }

    return widgets;
  }

  Future<void> _testConnection() async {
    if (_testingConnection) return;
    final err = _validateConnectionTest();
    final l10n = AppLocalizations.of(context)!;
    if (err != null) {
      setState(() {
        _testedOk = false;
        _testMsg = l10n.testFailed(err);
      });
      return;
    }

    // On-device STT has no cloud vendor to probe.
    if (_provider.asrVendorCode == null) {
      setState(() {
        _testedOk = true;
        _testMsg = l10n.testConnectionSuccess;
      });
      return;
    }

    setState(() {
      _testingConnection = true;
      _testedOk = false;
      _testMsg = l10n.processing;
    });
    final loading = AppDialogs.showLoading(
      context,
      message: l10n.processing,
      barrierDismissible: false,
    );
    try {
      final asrRepo = await ref.read(asrConfigRepositoryProvider.future);
      final cfg = _buildDraftConfig(asrRepo);
      final result = await asrRepo.testConnection(cfg);
      if (!mounted) return;
      setState(() {
        _testingConnection = false;
        _testedOk = result.ok;
        _testMsg = result.ok
            ? l10n.testConnectionSuccess
            : l10n.testFailed(
                result.message.trim().isEmpty
                    ? l10n.errorRequestFailed
                    : result.message.trim(),
              );
      });
    } on ServerException catch (e) {
      if (!mounted) return;
      setState(() {
        _testingConnection = false;
        _testedOk = false;
        _testMsg = l10n.testFailed(serverErrorDialogMessage(context, e));
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testingConnection = false;
        _testedOk = false;
        _testMsg = l10n.testFailed(friendlyLoadErrorMessage(context, e));
      });
    } finally {
      loading.close();
    }
  }

  Future<void> _save(bool isEdit) async {
    final asrRepo = await ref.read(asrConfigRepositoryProvider.future);
    final name = _name.text.trim();
    final key = _apiKey.text.trim();
    final extra = _buildExtraJsonForSave();
    final err = _validateInputs();
    if (err != null) {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        await AppDialogs.showErrorDialog(
          context,
          title: l10n.errorTitle,
          message: err,
          confirmText: l10n.confirm,
        );
      }
      return;
    }

    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final loading = AppDialogs.showLoading(context,
        message: l10n.processing, barrierDismissible: false);
    try {
      if (widget.existing == null) {
        final cfg = asrRepo.buildConfigForCreate(
          provider: _provider,
          name: name,
          apiKey: key,
          apiSecret:
              _apiSecret.text.trim().isEmpty ? null : _apiSecret.text.trim(),
          appId: _appId.text.trim().isEmpty ? null : _appId.text.trim(),
          accessKeyId: _accessKeyId.text.trim().isEmpty
              ? null
              : _accessKeyId.text.trim(),
          accessKeySecret: _accessKeySecret.text.trim().isEmpty
              ? null
              : _accessKeySecret.text.trim(),
          region: _region.text.trim().isEmpty ? null : _region.text.trim(),
          baseUrl: _baseUrl.text.trim().isEmpty ? null : _baseUrl.text.trim(),
          language:
              _language.text.trim().isEmpty ? null : _language.text.trim(),
          modelName: _modelNameForSave(),
          modelPath:
              _modelPath.text.trim().isEmpty ? null : _modelPath.text.trim(),
          extraJson: extra.isEmpty ? null : extra,
        );
        try {
          await asrRepo.createVendorToRemote(cfg);
        } catch (e) {
          if (mounted) {
            await AppDialogs.showErrorDialog(
              context,
              title: l10n.errorTitle,
              message: serverErrorDialogMessage(context, e),
              confirmText: l10n.confirm,
            );
          }
          return;
        }
      } else {
        final e = widget.existing!;
        final next = e.copyWith(
          provider: _provider,
          name: name,
          apiKey: key,
          apiSecret:
              _apiSecret.text.trim().isEmpty ? null : _apiSecret.text.trim(),
          appId: _appId.text.trim().isEmpty ? null : _appId.text.trim(),
          accessKeyId: _accessKeyId.text.trim().isEmpty
              ? null
              : _accessKeyId.text.trim(),
          accessKeySecret: _accessKeySecret.text.trim().isEmpty
              ? null
              : _accessKeySecret.text.trim(),
          region: _region.text.trim().isEmpty ? null : _region.text.trim(),
          baseUrl: _baseUrl.text.trim().isEmpty ? null : _baseUrl.text.trim(),
          language:
              _language.text.trim().isEmpty ? null : _language.text.trim(),
          modelName: _modelNameForSave(),
          modelPath:
              _modelPath.text.trim().isEmpty ? null : _modelPath.text.trim(),
          extraJson: extra.isEmpty ? null : extra,
        );
        try {
          if (e.provider != _provider) {
            final created = asrRepo.buildConfigForCreate(
              provider: _provider,
              name: name,
              apiKey: key,
              apiSecret: _apiSecret.text.trim().isEmpty
                  ? null
                  : _apiSecret.text.trim(),
              appId: _appId.text.trim().isEmpty ? null : _appId.text.trim(),
              accessKeyId: _accessKeyId.text.trim().isEmpty
                  ? null
                  : _accessKeyId.text.trim(),
              accessKeySecret: _accessKeySecret.text.trim().isEmpty
                  ? null
                  : _accessKeySecret.text.trim(),
              region: _region.text.trim().isEmpty ? null : _region.text.trim(),
              baseUrl:
                  _baseUrl.text.trim().isEmpty ? null : _baseUrl.text.trim(),
              language:
                  _language.text.trim().isEmpty ? null : _language.text.trim(),
              modelName: _modelNameForSave(),
              modelPath: _modelPath.text.trim().isEmpty
                  ? null
                  : _modelPath.text.trim(),
              extraJson: extra.isEmpty ? null : extra,
            );
            await asrRepo.createVendorToRemote(created);
            final oldRemoteId = e.asrRemoteVendorId;
            if (oldRemoteId != null) {
              try {
                await asrRepo.deleteVendorFromRemote(vendorId: oldRemoteId);
              } catch (_) {
                // best effort; the new config has already been created
              }
            }
          } else {
            await asrRepo.updateVendorToRemote(next);
          }
        } catch (e) {
          if (mounted) {
            await AppDialogs.showErrorDialog(
              context,
              title: l10n.errorTitle,
              message: serverErrorDialogMessage(context, e),
              confirmText: l10n.confirm,
            );
          }
          return;
        }
      }
      if (mounted) Navigator.of(context).pop();
    } finally {
      loading.close();
    }
  }

  Future<void> _delete() async {
    final e = widget.existing;
    if (e == null) return;
    final l10n = AppLocalizations.of(context)!;
    final ok = await AppDialogs.showDeleteConfirm(
      context,
      title: l10n.deleteConfigurationTitle,
      message: l10n.deleteConfigurationConfirm(e.name),
      deleteText: l10n.delete,
    );
    if (!ok) return;
    final asrRepo = await ref.read(asrConfigRepositoryProvider.future);
    final remoteId = e.asrRemoteVendorId;
    if (remoteId != null) {
      try {
        await asrRepo.deleteVendorFromRemote(vendorId: remoteId);
      } catch (err) {
        if (mounted) {
          final l10n = AppLocalizations.of(context)!;
          await AppDialogs.showErrorDialog(
            context,
            title: l10n.errorTitle,
            message: l10n.deletedLocalDeleteFailed(err.toString()),
            confirmText: l10n.confirm,
          );
        }
      }
    }
    if (mounted) Navigator.of(context).pop();
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            text,
            textAlign: TextAlign.left,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w500,
              fontSize: AppTypography.s12,
            ),
          ),
        ),
      );
}

class _SheetScrollWrapper extends StatelessWidget {
  final Widget child;
  const _SheetScrollWrapper({required this.child});

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return LayoutBuilder(
      builder: (ctx, c) {
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: c.maxHeight),
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.only(bottom: bottom + 24),
            child: child,
          ),
        );
      },
    );
  }
}
