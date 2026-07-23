import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_typography.dart';
import 'app_pill_button.dart';

/// M3 calendar date picker portrait size + [kAppDatePickerActionInset] bottom gap.
const double kAppDatePickerDialogWidth = 360;
const double kAppDatePickerDialogHeight = 568 + kAppDatePickerActionInset;
const double kAppDatePickerHeaderHeight = 120;
const double kAppDatePickerActionHeight = 48;
const double kAppDatePickerPrimaryActionWidth = 100;
const double kAppDatePickerActionInset = 24;

/// App-styled date picker with correct bottom action inset.
///
/// Material [showDatePicker] ignores [DialogTheme.actionsPadding] for its
/// action row; this dialog applies [kAppDatePickerActionInset] explicitly.
Future<DateTime?> showAppDatePicker({
  required BuildContext context,
  DateTime? initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
  String? helpText,
  String? cancelText,
  String? confirmText,
}) {
  return showDialog<DateTime>(
    context: context,
    builder: (dialogContext) => Theme(
      data: _appDatePickerTheme(dialogContext),
      child: _AppDatePickerDialog(
        initialDate: initialDate,
        firstDate: firstDate,
        lastDate: lastDate,
        helpText: helpText,
        cancelText: cancelText,
        confirmText: confirmText,
      ),
    ),
  );
}

ThemeData _appDatePickerTheme(BuildContext context) {
  return Theme.of(context).copyWith(
    colorScheme: Theme.of(context).colorScheme.copyWith(
      primary: AppColors.buttonPrimaryBg,
      onPrimary: Colors.white,
    ),
    datePickerTheme: DatePickerThemeData(
      headerBackgroundColor: AppColors.buttonPrimaryBg,
      headerForegroundColor: Colors.white,
      headerHelpStyle: const TextStyle(
        fontSize: AppTypography.s18,
        fontWeight: FontWeight.w500,
        color: Colors.white,
      ),
      headerHeadlineStyle: const TextStyle(
        fontSize: AppTypography.s16,
        fontWeight: FontWeight.w500,
        color: Colors.white,
      ),
      dayBackgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return AppColors.buttonPrimaryBg;
        }
        return null;
      }),
      dayForegroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return Colors.white;
        }
        return null;
      }),
      todayBorder: const BorderSide(color: AppColors.buttonPrimaryBg, width: 2),
    ),
  );
}

class _AppDatePickerDialog extends StatefulWidget {
  const _AppDatePickerDialog({
    this.initialDate,
    required this.firstDate,
    required this.lastDate,
    this.helpText,
    this.cancelText,
    this.confirmText,
  });

  final DateTime? initialDate;
  final DateTime firstDate;
  final DateTime lastDate;
  final String? helpText;
  final String? cancelText;
  final String? confirmText;

  @override
  State<_AppDatePickerDialog> createState() => _AppDatePickerDialogState();
}

class _AppDatePickerDialogState extends State<_AppDatePickerDialog> {
  late DateTime _selectedDate;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialDate ?? DateTime.now();
    _selectedDate = _clampDate(initial);
  }

  DateTime _clampDate(DateTime date) {
    if (date.isBefore(widget.firstDate)) return widget.firstDate;
    if (date.isAfter(widget.lastDate)) return widget.lastDate;
    return date;
  }

  DateTime _dateOnly(DateTime date) =>
      DateTime(date.year, date.month, date.day);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final useMaterial3 = theme.useMaterial3;
    final datePickerTheme = DatePickerTheme.of(context);
    final defaults = DatePickerTheme.defaults(context);
    final localizations = MaterialLocalizations.of(context);

    final headerBackgroundColor =
        datePickerTheme.headerBackgroundColor ?? defaults.headerBackgroundColor;
    final headerForegroundColor =
        datePickerTheme.headerForegroundColor ?? defaults.headerForegroundColor;
    final helpStyle = (datePickerTheme.headerHelpStyle ?? defaults.headerHelpStyle)
        ?.copyWith(color: headerForegroundColor);
    final headlineStyle =
        (datePickerTheme.headerHeadlineStyle ?? defaults.headerHeadlineStyle)
            ?.copyWith(color: headerForegroundColor);

    final helpText = widget.helpText ?? localizations.datePickerHelpText;
    final titleText = localizations.formatMediumDate(_selectedDate);
    final cancelLabel =
        widget.cancelText ?? localizations.cancelButtonLabel;
    final confirmLabel = widget.confirmText ?? localizations.okButtonLabel;

    return Dialog(
      backgroundColor:
          datePickerTheme.backgroundColor ?? defaults.backgroundColor,
      elevation: datePickerTheme.elevation ?? defaults.elevation ?? 6,
      shadowColor: datePickerTheme.shadowColor ?? defaults.shadowColor,
      surfaceTintColor:
          datePickerTheme.surfaceTintColor ?? defaults.surfaceTintColor,
      shape: useMaterial3
          ? datePickerTheme.shape ?? defaults.shape
          : datePickerTheme.shape ?? theme.dialogTheme.shape ?? defaults.shape,
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: kAppDatePickerDialogWidth,
        height: kAppDatePickerDialogHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: kAppDatePickerHeaderHeight,
              child: Material(
                color: headerBackgroundColor,
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(
                    start: 24,
                    end: 12,
                    bottom: 12,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 16),
                      Text(
                        helpText,
                        style: helpStyle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const Spacer(),
                      Text(
                        titleText,
                        style: headlineStyle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Divider(height: 0, color: datePickerTheme.dividerColor),
            Expanded(
              child: CalendarDatePicker(
                initialDate: _selectedDate,
                firstDate: widget.firstDate,
                lastDate: widget.lastDate,
                currentDate: _dateOnly(DateTime.now()),
                onDateChanged: (date) => setState(() => _selectedDate = date),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(
                top: 8,
                right: kAppDatePickerActionInset,
                bottom: kAppDatePickerActionInset,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  AppOutlinedPillButton(
                    label: cancelLabel,
                    onPressed: () => Navigator.of(context).pop(),
                    height: kAppDatePickerActionHeight,
                    fullWidth: false,
                    foregroundColor: AppColors.textPrimary,
                    borderColor: AppColors.borderLight,
                    textStyle: const TextStyle(
                      fontSize: AppTypography.s14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 24),
                  SizedBox(
                    width: kAppDatePickerPrimaryActionWidth,
                    height: kAppDatePickerActionHeight,
                    child: AppBlackPillButton(
                      label: confirmLabel,
                      onPressed: () => Navigator.of(context).pop(_selectedDate),
                      height: kAppDatePickerActionHeight,
                      textStyle: const TextStyle(
                        fontSize: AppTypography.s14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
