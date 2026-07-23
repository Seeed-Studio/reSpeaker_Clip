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
import '../../../../core/widgets/app_pill_button.dart';
import '../../../../core/widgets/app_dialogs.dart';
import '../../data/llm_config_remote_repository.dart';
import '../../domain/ai_providers.dart';
import '../../domain/llm_config.dart';
import 'ai_config_validation.dart';
import 'ai_config_field_caption.dart';

Future<void> showLlmConfigEditorSheet(
  BuildContext context, {
  LlmConfig? existing,
}) async {
  await showAppBottomSheet<void>(
    context,
    builder: (_) =>
        _SheetScrollWrapper(child: LlmConfigEditorSheet(existing: existing)),
  );
}

class LlmConfigEditorSheet extends ConsumerStatefulWidget {
  final LlmConfig? existing;
  const LlmConfigEditorSheet({super.key, required this.existing});

  @override
  ConsumerState<LlmConfigEditorSheet> createState() =>
      _LlmConfigEditorSheetState();
}

class _LlmConfigEditorSheetState extends ConsumerState<LlmConfigEditorSheet> {
  late LlmProvider _provider;
  late final TextEditingController _name;
  late final TextEditingController _apiKey;
  late final TextEditingController _apiSecret;
  late final TextEditingController _appId;
  late final TextEditingController _accessKeyId;
  late final TextEditingController _accessKeySecret;
  late final TextEditingController _region;
  late final TextEditingController _baseUrl;
  late final TextEditingController _modelName;
  late final TextEditingController _moduleName;
  late final TextEditingController _extraJson;

  bool _showKey = false;
  bool _testedOk = false;
  bool _testingConnection = false;
  String? _testMsg;
  bool _showAdvanced = false;
  bool _showProviderList = false;
  bool _didApplyDefaultLocalizedName = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _provider = e?.provider ?? LlmProvider.openAi;
    _name = TextEditingController(text: e?.name ?? _provider.label);
    _apiKey = TextEditingController(text: e?.apiKey ?? '');
    _apiSecret = TextEditingController(text: e?.apiSecret ?? '');
    _appId = TextEditingController(text: e?.appId ?? '');
    _accessKeyId = TextEditingController(text: e?.accessKeyId ?? '');
    _accessKeySecret = TextEditingController(text: e?.accessKeySecret ?? '');
    _region = TextEditingController(text: e?.region ?? '');
    _baseUrl =
        TextEditingController(text: e?.baseUrl ?? _provider.defaultBaseUrl);
    _modelName = TextEditingController(text: e?.modelName ?? '');
    _moduleName = TextEditingController(text: e?.moduleName ?? '');
    _extraJson = TextEditingController(text: e?.extraJson ?? '');
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
        _modelName,
        _moduleName,
        _extraJson,
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
    _name.text = _provider.labelFor(l10n);
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
    _modelName.dispose();
    _moduleName.dispose();
    _extraJson.dispose();
    super.dispose();
  }

  String? _validateInputs() {
    final l10n = AppLocalizations.of(context)!;
    return validateLlmInputs(
      provider: _provider,
      name: _name.text,
      apiKey: _apiKey.text,
      baseUrl: _baseUrl.text,
      modelName: _modelName.text,
      l10n: l10n,
    );
  }

  String? _validateConnectionTest() {
    final l10n = AppLocalizations.of(context)!;
    return validateLlmConnectionTest(
      provider: _provider,
      name: _name.text,
      apiKey: _apiKey.text,
      accessKeyId: _accessKeyId.text,
      baseUrl: _baseUrl.text,
      modelName: _modelName.text,
      l10n: l10n,
    );
  }

  String? _modelNameForSave() {
    final model = _modelName.text.trim();
    if (model.isEmpty) return null;
    if (_provider == LlmProvider.googleGemini) {
      return normalizeGeminiModelNameInput(model);
    }
    return model;
  }

  LlmConfig _buildDraftConfig(LlmConfigRemoteRepository remoteRepo) {
    final name = _name.text.trim();
    final key = _apiKey.text.trim();
    return remoteRepo.buildConfigForCreate(
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
      modelName: _modelNameForSave(),
      moduleName:
          _moduleName.text.trim().isEmpty ? null : _moduleName.text.trim(),
      extraJson:
          _extraJson.text.trim().isEmpty ? null : _extraJson.text.trim(),
    );
  }

  void _applyProvider(LlmProvider picked, AppLocalizations l10n) {
    setState(() {
      _provider = picked;
      _apiKey.text = '';
      _apiSecret.text = '';
      _appId.text = '';
      _accessKeyId.text = '';
      _accessKeySecret.text = '';
      _region.text = '';
      _extraJson.text = '';
      _name.text = _provider.labelFor(l10n);
      _baseUrl.text = _provider.defaultBaseUrl;
      _modelName.text = '';
      _moduleName.text = '';
      _testedOk = false;
      _testMsg = null;
      _testingConnection = false;
      _showProviderList = false;
    });
  }

  Widget _buildProviderList(
    BuildContext context,
    AppLocalizations l10n,
    InputDecoration Function({String? hintText, Widget? suffixIcon}) inputDeco,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.r18),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(
        children: [
          for (var i = 0; i < LlmProvider.values.length; i++) ...[
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => _applyProvider(LlmProvider.values[i], l10n),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(i == 0 ? AppRadii.r18 : 0),
                  topRight: Radius.circular(i == 0 ? AppRadii.r18 : 0),
                  bottomLeft: Radius.circular(
                      i == LlmProvider.values.length - 1 ? AppRadii.r18 : 0),
                  bottomRight: Radius.circular(
                      i == LlmProvider.values.length - 1 ? AppRadii.r18 : 0),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          LlmProvider.values[i].labelFor(l10n),
                          style: const TextStyle(
                            fontSize: AppTypography.s14,
                            fontWeight: FontWeight.w500,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      if (LlmProvider.values[i] == _provider)
                        Icon(Icons.check_circle,
                            size: 18,
                            color: Theme.of(context).colorScheme.primary),
                    ],
                  ),
                ),
              ),
            ),
            if (i != LlmProvider.values.length - 1)
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
                _buildProviderList(context, l10n, inputDeco),
              ],
              const SizedBox(height: 12),
              _FieldLabel(l10n.fieldLabelName),
              TextField(
                  controller: _name,
                  textAlignVertical: TextAlignVertical.center,
                  decoration: inputDeco()),
              const SizedBox(height: 12),
              _FieldLabel(llmApiKeyIsRequired(_provider)
                  ? l10n.fieldLabelApiKeyRequired
                  : l10n.fieldLabelApiKeyOptional),
              TextField(
                controller: _apiKey,
                obscureText: !_showKey,
                textAlignVertical: TextAlignVertical.center,
                decoration: InputDecoration(
                  hintText: _provider.apiKeyHint(l10n),
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
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => _showKey = !_showKey),
                    icon: Icon(
                        _showKey ? Icons.visibility_off : Icons.visibility),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _FieldLabel(llmBaseUrlIsRequired(_provider)
                  ? l10n.fieldLabelBaseUrlRequired
                  : l10n.fieldLabelBaseUrlOptional),
              TextField(
                  controller: _baseUrl,
                  textAlignVertical: TextAlignVertical.center,
                  decoration: inputDeco(hintText: _provider.baseUrlHint(l10n))),
              const SizedBox(height: 12),
              _FieldLabel(_provider.modelNameRequired
                  ? l10n.fieldLabelModelNameRequired
                  : l10n.fieldLabelModelNameOptional),
              TextField(
                controller: _modelName,
                textAlignVertical: TextAlignVertical.center,
                decoration: inputDeco(hintText: _provider.modelNameHint(l10n)),
              ),
              AiConfigFieldCaption(_provider.modelFieldCaption(l10n)),
              const SizedBox(height: 12),
              _FieldLabel(l10n.fieldLabelModuleNameOptional),
              TextField(
                  controller: _moduleName,
                  textAlignVertical: TextAlignVertical.center,
                  decoration: inputDeco()),
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
                _FieldLabel(l10n.fieldLabelApiSecretOptional),
                TextField(
                    controller: _apiSecret,
                    textAlignVertical: TextAlignVertical.center,
                    decoration: inputDeco()),
                const SizedBox(height: 12),
                _FieldLabel(l10n.fieldLabelAppIdOptional),
                TextField(
                    controller: _appId,
                    textAlignVertical: TextAlignVertical.center,
                    decoration: inputDeco()),
                const SizedBox(height: 12),
                _FieldLabel(l10n.fieldLabelAccessKeyIdOptional),
                TextField(
                    controller: _accessKeyId,
                    textAlignVertical: TextAlignVertical.center,
                    decoration: inputDeco()),
                const SizedBox(height: 12),
                _FieldLabel(l10n.fieldLabelAccessKeySecretOptional),
                TextField(
                    controller: _accessKeySecret,
                    textAlignVertical: TextAlignVertical.center,
                    decoration: inputDeco()),
                const SizedBox(height: 12),
                _FieldLabel(l10n.fieldLabelRegionOptional),
                TextField(
                    controller: _region,
                    textAlignVertical: TextAlignVertical.center,
                    decoration: inputDeco()),
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
      final remoteRepo = await ref.read(llmConfigRemoteRepositoryProvider.future);
      final cfg = _buildDraftConfig(remoteRepo);
      final result = await remoteRepo.testConnection(cfg);
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
    final remoteRepo = await ref.read(llmConfigRemoteRepositoryProvider.future);
    final name = _name.text.trim();
    final key = _apiKey.text.trim();
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
        final cfg = remoteRepo.buildConfigForCreate(
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
          modelName: _modelNameForSave(),
          moduleName:
              _moduleName.text.trim().isEmpty ? null : _moduleName.text.trim(),
          extraJson:
              _extraJson.text.trim().isEmpty ? null : _extraJson.text.trim(),
        );
        try {
          await remoteRepo.createConfigToRemote(cfg);
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
          modelName: _modelNameForSave(),
          moduleName:
              _moduleName.text.trim().isEmpty ? null : _moduleName.text.trim(),
          extraJson:
              _extraJson.text.trim().isEmpty ? null : _extraJson.text.trim(),
        );
        try {
          if (e.provider != _provider) {
            final created = remoteRepo.buildConfigForCreate(
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
              modelName: _modelNameForSave(),
              moduleName: _moduleName.text.trim().isEmpty
                  ? null
                  : _moduleName.text.trim(),
              extraJson: _extraJson.text.trim().isEmpty
                  ? null
                  : _extraJson.text.trim(),
            );
            await remoteRepo.createConfigToRemote(created);
            try {
              await remoteRepo.deleteConfigFromRemote(e);
            } catch (_) {
              // best effort; the new config has already been created
            }
          } else {
            await remoteRepo.updateConfigToRemote(next);
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
    final remoteRepo = await ref.read(llmConfigRemoteRepositoryProvider.future);
    try {
      await remoteRepo.deleteConfigFromRemote(e);
    } catch (err) {
      if (mounted) {
        await AppDialogs.showErrorDialog(
          context,
          title: l10n.errorTitle,
          message: l10n.deletedLocalDeleteFailed(err.toString()),
          confirmText: l10n.confirm,
        );
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
