/// Exact strings required by Seeed AI Bot voice feedback workflow.
abstract final class FeedbackWorkflowValues {
  static const formTypeVoiceFeedback = 'voice_feedback';
  static const modeProd = 'prod';
  static const modeTest = 'test';
}

/// Map app login/runtime env to workflow notify mode.
String feedbackWorkflowModeFromAppEnv(String? env) {
  final e = (env ?? '').trim().toLowerCase();
  switch (e) {
    case 'prod':
    case 'production':
    case 'release':
      return FeedbackWorkflowValues.modeProd;
    default:
      return FeedbackWorkflowValues.modeTest;
  }
}
