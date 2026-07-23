import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'feedback_workflow_api.dart';

final feedbackWorkflowApiProvider = Provider<FeedbackWorkflowApi>((ref) {
  return FeedbackWorkflowApi();
});
