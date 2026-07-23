# App Store Review Response - AI Data Sharing

## Reply to App Review

Hello App Review Team,

Thank you for the review. We updated the app to clearly disclose AI data sharing before any AI processing starts.

In version 1.0.0, when a user taps transcription, batch transcription, or summary generation, the app now shows an in-app consent dialog before sending any recording data. The dialog explains:

- What data may be sent: selected recording audio for speech-to-text, transcript text for summary generation, and related request metadata such as recording ID, device ID, language, speaker-labeling option, and selected AI configuration.
- Who receives the data: SenseCraft Voice cloud service and the AI provider selected by the user, such as OpenAI, Google Gemini, Deepgram, Anthropic Claude, DeepSeek, Qwen, OpenRouter, Aliyun, iFlytek, Tencent, Baidu, or Doubao depending on the user's configuration.
- Why the data is sent: only to provide the user-requested transcription or summary result.
- That the user must check the consent checkbox and tap "Allow and continue" before the app sends the data.

If the user declines, the app does not start the transcription or summary request and no AI data is sent.

We will also update the Privacy Policy to describe the audio, transcript, and metadata collection, how the data is collected, how it is used, and the third-party AI providers that may process it.

## Privacy Policy Addendum Draft

When you use AI transcription or summary features, SenseCraft Voice may collect and process the following data only after you request the feature and provide in-app consent:

- Recording audio: used to generate speech-to-text transcripts.
- Transcript text: used to generate AI summaries.
- Request metadata: recording ID, device ID, language setting, speaker-labeling option, selected AI configuration, and processing status.

This data is sent to SenseCraft Voice cloud services and may be shared with the AI service provider selected or configured by the user, including OpenAI, Google Gemini, Deepgram, Anthropic Claude, DeepSeek, Qwen, OpenRouter, Aliyun, iFlytek, Tencent, Baidu, or Doubao. The exact provider depends on the user's selected STT or LLM configuration.

We use this data only to provide the requested transcription, speaker-labeling, or summary result. We do not send recording audio or transcript text to third-party AI services unless the user starts an AI feature and confirms the in-app data sharing consent. Third-party providers are required to handle the data under protections that are the same as or equivalent to those described in this Privacy Policy.
