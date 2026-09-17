import 'package:flutter/material.dart';

import '../../core/app_theme.dart';

/// Snackbars, used everywhere an action needs to confirm itself or offer undo.
///
/// Errors get the error container colour and a Retry affordance — the app
/// never swallows a failed export or save.
abstract final class AppFeedback {
  static void show(
    BuildContext context,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    bool isError = false,
    Duration duration = const Duration(seconds: 4),
    VoidCallback? onDismissed,
  }) {
    final colors = Theme.of(context).colorScheme;
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();

    messenger
        .showSnackBar(
          SnackBar(
            content: Text(
              message,
              style: TextStyle(
                color: isError ? colors.onErrorContainer : colors.surface,
                fontWeight: FontWeight.w500,
              ),
            ),
            backgroundColor: isError ? colors.errorContainer : colors.onSurface,
            duration: duration,
            action: actionLabel == null
                ? null
                : SnackBarAction(
                    label: actionLabel,
                    textColor: isError ? colors.error : colors.primary,
                    onPressed: onAction ?? () {},
                  ),
          ),
        )
        .closed
        .then((_) => onDismissed?.call());
  }

  static void error(
    BuildContext context,
    String message, {
    VoidCallback? onRetry,
  }) =>
      show(
        context,
        message,
        isError: true,
        actionLabel: onRetry == null ? null : 'Retry',
        onAction: onRetry,
        duration: const Duration(seconds: 6),
      );
}

/// A confirmation dialog matching the prototype's rounded card.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final colors = Theme.of(context).colorScheme;
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, letterSpacing: -0.4)),
      content: Text(message, style: TextStyle(height: 1.5, color: context.tones.fg2)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text('Cancel', style: TextStyle(color: context.tones.fg2)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: destructive ? colors.error : colors.primary,
            foregroundColor: destructive ? colors.onError : colors.onPrimary,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}
