# Clip Audio Quality Test Standard

## 1. Overview

This document defines the testing standards and methods for evaluating the audio recording quality of the reSpeaker Clip device. Clip recordings are primarily used for **speech-to-text (ASR)** and **content summarization**. The core requirements are speech intelligibility and transcription accuracy. The target language is **Chinese and English mixed**.

### 1.1 Audio Signal Chain

```
PDM Microphones (x2, 16kHz, 16-bit, +20dB gain)
    |
SpeexDSP Preprocessing (Enhanced only)
    +-- Noise Suppression (default 12 dB)
    +-- Dereverberation (level 40, decay 30)
    +-- (SpeexDSP AGC unavailable in FIXED_POINT; custom integer AGC
        + high-pass run in BOTH presets)
    |
Opus Encoding (16kHz, 20ms frames, VBR, AUDIO application)
    +-- Normal:   mono, 32 kbps, complexity 1 (SpeexDSP bypassed)
    +-- Enhanced: mono, 32 kbps, complexity 1 (SpeexDSP NS/DR enabled)
    |
SD Card Storage (raw Opus frames)
```

### 1.2 Recording Preset Comparison

| Feature | Normal | Enhanced |
|---------|--------|----------|
| Channels | 1 (L+R merged) | 1 (L+R merged) |
| SpeexDSP | Bypassed | Noise suppression + Dereverb |
| AGC / HPF | Integer AGC + HPF | Integer AGC + HPF |
| Opus Bitrate | 32 kbps | 32 kbps |
| Use Case | Lower-CPU capture; no noise processing | Far-field speech, real-time transcription |

---

## 2. Quality Metrics

### 2.1 Metric Definitions

#### SNR (Signal-to-Noise Ratio)

- **Description**: Ratio of speech signal power to background noise power, in dB
- **Formula**: `SNR = 10 * log10(P_signal / P_noise)`
- **Method**: Record a silent segment to get noise power, then record speech to get signal power; alternatively, compare against a reference signal
- **Significance**: Higher SNR means clearer speech. ASR accuracy drops significantly below 15 dB

#### STOI (Short-Time Objective Intelligibility)

- **Description**: Short-time speech intelligibility index, range 0~1
- **Formula**: Time-frequency domain correlation between reference and degraded signals
- **Method**: Python `pystoi` library
- **Significance**: Directly predicts human speech comprehension. >0.85 is excellent

#### PESQ (Perceptual Evaluation of Speech Quality)

- **Description**: Perceptual speech quality assessment, range -0.5~4.5 (ITU-T P.862)
- **Formula**: Simulates human auditory perception, compares reference vs test signal
- **Method**: Python `pesq` library (requires 16kHz sample rate)
- **Significance**: Comprehensive quality metric covering distortion, noise, and codec loss. >3.0 is good

#### WER (Word Error Rate)

- **Description**: Word-level error rate between ASR transcription and reference text
- **Formula**: `WER = (S + D + I) / N` (substitutions + deletions + insertions) / total words
- **Method**: ASR engine (Whisper) transcription, align with reference text, compute WER
- **Significance**: The most direct transcription quality metric and ultimate business metric

#### THD (Total Harmonic Distortion)

- **Description**: Measures non-linear distortion
- **Formula**: `THD = sqrt(P2 + P3 + ... + Pn) / P1` (harmonic power / fundamental power)
- **Method**: Play a pure sine wave, record it, analyze harmonics via FFT
- **Significance**: High THD indicates hardware or DSP distortion, affecting speech clarity

### 2.2 Target Values

| Metric | Quiet Target | Noisy Target | Minimum Acceptable |
|--------|-------------|-------------|-------------------|
| SNR | >= 25 dB | >= 12 dB | 10 dB |
| STOI | >= 0.90 | >= 0.80 | 0.75 |
| PESQ | >= 3.5 | >= 2.5 | 2.0 |
| WER (Chinese) | <= 8% | <= 20% | 25% |
| WER (English) | <= 5% | <= 15% | 20% |
| THD | <= 3% | <= 5% | 8% |

> **Quiet**: ambient noise <= 40 dB(A)
> **Noisy**: ambient noise 50-65 dB(A)

---

## 3. Test Scenarios

### 3.1 Environment Scenarios

| ID | Scenario | Distance | Ambient Noise | Simulation Method |
|----|----------|----------|---------------|-------------------|
| S1 | Quiet near-field | 0.3m | <= 35 dB(A) | Anechoic room / quiet room at night |
| S2 | Quiet far-field | 1.0m | <= 35 dB(A) | Anechoic room / quiet room at night |
| S3 | Quiet far-field | 2.0m | <= 35 dB(A) | Anechoic room / large quiet room |
| S3a | Quiet ultra-far | 3.0m | <= 35 dB(A) | Large quiet room / meeting room |
| S4 | Office | 1.0m | ~50 dB(A) | Air conditioning + keyboard typing |
| S5 | Cafe | 1.0m | ~60 dB(A) | Real cafe or playback of cafe noise |
| S6 | In-car | 0.5m | ~55 dB(A) | Driving with windows partially open |
| S7 | Outdoor street | 1.0m | ~65 dB(A) | Street side or playback of traffic noise |

### 3.2 Test Matrix

Each scenario x 2 modes = **16 test groups**

| Scenario | Normal | Enhanced |
|----------|--------|----------|
| S1 Quiet near-field | Y | Y |
| S2 Quiet far-field | Y | Y |
| S3 Quiet ultra-far (2m) | Y | Y |
| S3a Quiet ultra-far (3m) | Y | Y |
| S4 Office | Y | Y |
| S5 Cafe | Y | Y |
| S6 In-car | Y | Y |
| S7 Outdoor street | Y | Y |

### 3.3 Per-Test Contents

1. **Chinese corpus**: 20 balanced sentences (~3 min)
2. **English corpus**: 20 standard sentences (~3 min)
3. **Digit sequences**: 10 random groups (digits 0-9, 8 digits per group)
4. **Silence segment**: 10 seconds of no speech (for noise floor analysis)

---

## 4. Test Corpus

### 4.1 Chinese Balanced Corpus

Covers all 23 initials and 24 finals with tone variation:

```
 1. 今天天气很好，我们去公园散步吧。             (t, q, j, g, h, b, s, p)
 2. 明天早上八点开会，请准时到场。               (m, d, z, h, k, q, ch)
 3. 这个项目的预算已经超过了原定计划。           (zh, g, x, y, s, j, ch, l)
 4. 人工智能技术正在改变我们的生活方式。         (r, g, zh, j, sh, b, f)
 5. 请把窗户打开，房间太闷了。                   (q, b, ch, h, d, k, f, m)
 6. 他每天晚上都会看一个小时的书。               (t, m, w, sh, d, h, k, y, x, sh)
 7. 这道菜的口味偏辣，不太适合老人和小孩。       (zh, d, c, k, p, l, b, sh, h, x)
 8. 会议结束后，我们需要整理一份详细的报告。     (h, y, j, sh, w, m, x, y, z, l, f, x, b)
 9. 上周末我去了一趟上海，参观了几家博物馆。     (sh, zh, m, w, q, t, h, c, g, j, b)
10. 春天的风景最美，到处都是鲜花和绿树。         (ch, f, d, z, m, ch, d, sh, x, h, l)
11. 老师建议我们先复习基础知识，再做练习题。     (l, sh, j, y, w, f, x, j, ch, z, l, x)
12. 火车站离这里不远，走路大概十五分钟。         (h, ch, z, l, zh, b, y, z, l, d, g, sh, f, z)
13. 服务员问我们要不要加点辣椒油。               (f, w, y, w, y, j, d, l, j, y)
14. 我们的产品具有高质量和优秀的性能。           (w, g, ch, p, j, y, g, zh, l, x, y, x)
15. 这部电影的剧情很精彩，值得推荐给大家。       (zh, b, d, j, q, h, j, c, zh, d, t, j, d, j)
16. 他是一位非常出色的工程师，解决了很多难题。   (sh, w, f, ch, s, g, ch, sh, j, j, h, d, n)
17. 夏天的时候，孩子们喜欢去河边游泳。           (x, sh, h, m, x, h, q, h, b, y)
18. 这篇文章的重点是分析数据趋势和规律。         (zh, p, zh, d, sh, f, x, sh, j, q, g, l)
19. 每年春节，全家人都会聚在一起吃年夜饭。       (m, n, ch, j, q, j, r, d, h, j, z, y, ch)
20. 新款手机的功能越来越强大，价格也很合理。     (x, k, sh, j, g, n, y, l, y, q, d, j, g, h, l)
```

### 4.2 English Standard Corpus

Harvard sentence set covering common English phoneme combinations:

```
 1. The birch canoe slid on the smooth planks.
 2. Glue the sheet to the dark blue background.
 3. It is easy to tell the depth of a well.
 4. These days a chicken leg is a rare dish.
 5. Rice is often served in round bowls.
 6. The juice of lemons makes fine punch.
 7. The box was thrown beside the parked truck.
 8. The hogs were fed chopped corn and garbage.
 9. Four hours of steady work faced us.
10. A large size in stockings is hard to sell.
11. The boy was there when the sun rose.
12. A rod is used to catch pink salmon.
13. The source of the huge river is the clear spring.
14. Kick the ball straight and follow through.
15. Help the woman get back to her feet.
16. A pot of tea helps to pass the evening.
17. Smoky fires lack flame and heat.
18. The soft cushion broke the man's fall.
19. The salt breeze came across from the sea.
20. The girl at the booth sold fifty bonds.
```

### 4.3 Digit Sequences

For testing digit recognition accuracy:

```
 1. 3-8-2-7-1-9-5-4
 2. 6-0-4-9-2-8-1-7
 3. 5-1-9-3-7-6-0-2
 4. 8-4-2-6-0-5-9-1
 5. 1-7-3-5-9-2-8-4
 6. 9-0-6-4-1-7-3-5
 7. 2-5-8-1-4-7-0-6
 8. 7-2-9-4-6-1-5-0
 9. 4-6-0-8-3-5-7-2
10. 0-3-7-1-8-4-6-9
```

---

## 5. Test Methods

### 5.1 Hardware Requirements

| Equipment | Purpose | Requirements |
|-----------|---------|--------------|
| Calibrated loudspeaker | Play reference audio | Flat frequency response 100Hz-10kHz |
| Sound level meter | Measure ambient noise | A-weighted, accuracy +/-1.5 dB |
| Measuring tape | Measure distance | Accuracy +/-5cm |
| Test phone/laptop | Play reference audio | With external speaker |
| Clip device | Device under test | Consistent firmware version |

### 5.2 Objective Test Procedure

```
Step 1: Prepare Reference Audio
    +-- Use TTS or human-recorded standard corpus -> 16kHz WAV reference file
    +-- Or use synthetic signals (sine sweep, white noise, etc.)

Step 2: Environment Calibration
    +-- Use sound level meter to verify ambient noise matches scenario requirements
    +-- Adjust speaker volume to 65 dB(A) at 1m (simulating normal speech level)
    +-- Record actual noise level and speaker volume

Step 3: Recording
    +-- Place Clip device at specified distance, microphones facing the sound source
    +-- Start recording in specified mode (Normal/Enhanced)
    +-- Play reference audio (include 2s leading/trailing silence for alignment)
    +-- Stop recording, export file

Step 4: File Processing
    +-- Export recorded Opus file -> decode to 16kHz WAV
    |   (use tests/tools/decode_opus.py or ffmpeg)
    +-- Analyze the mono recordings directly

Step 5: Alignment and Calculation
    +-- Cross-correlate to align reference audio with recording
    +-- Calculate SNR / STOI / PESQ / THD
    +-- Record all metric values

Step 6: ASR Verification
    +-- Transcribe recording using Whisper large-v3 model
    +-- Align transcription with reference text
    +-- Calculate WER (character-level for Chinese, word-level for English)
    +-- Record WER and specific errors
```

### 5.3 ASR Transcription Verification

Recommended: **Whisper** (OpenAI), run locally:

```bash
# Install
pip install openai-whisper

# Transcribe (Chinese)
whisper recording.wav --model large-v3 --language zh

# Transcribe (English)
whisper recording.wav --model large-v3 --language en

# Transcribe (auto-detect language)
whisper recording.wav --model large-v3
```

WER calculation:
- **Chinese**: Character-level, ignore punctuation
- **English**: Word-level, case-insensitive
- Use `jiwer` library: `pip install jiwer`

### 5.4 Subjective MOS Scoring

Each recording is independently scored by 3+ evaluators:

| MOS Score | Description |
|-----------|-------------|
| 5 (Excellent) | Perfectly clear, no noise or distortion |
| 4 (Good) | Clear, occasional slight noise |
| 3 (Fair) | Intelligible, noticeable noise or slight distortion |
| 2 (Poor) | Hard to understand, requires full concentration |
| 1 (Bad) | Unintelligible |

Scoring criterion: **"Can this recording be used directly for speech-to-text?"**
- 5: Absolutely, no issues
- 4: Transcription accuracy > 95%
- 3: Transcription accuracy 80-95%
- 2: Transcription accuracy 50-80%
- 1: Cannot be transcribed

---

## 6. Current Parameter Analysis and Optimization

### 6.1 Current Parameters

| Parameter | Normal Mode | Enhanced Mode | Notes |
|-----------|------------|--------------|-------|
| Opus bitrate | 32 kbps | 32 kbps | Both presets use ENHANCED_BITRATE |
| Opus complexity | 1 (0-10 scale) | 1 (0-10 scale) | Lowest setting |
| Opus application | AUDIO | AUDIO | Preserves fricatives for STT |
| Channels | 1 (mono) | 1 (mono) | -- |
| Noise suppression | Off | On (default 12 dB) | SpeexDSP |
| Dereverberation | Off | On (level 40 / decay 30) | SpeexDSP |
| AGC | On (integer) | On (integer) | SpeexDSP AGC unavailable; custom AGC runs in both |

### 6.2 Parameter Impact on Transcription Quality

**Opus Bitrate**:
- Both presets are mono at 32 kbps, so the per-channel rate is 32 kbps.
- 32 kbps mono is usually sufficient for speech; if higher ASR quality is needed, raise `CONFIG_CLIP_ENHANCED_BITRATE` (used by both presets).
- The normal Kconfig bitrate/complexity constants are currently unused.

**Opus Complexity**:
- complexity=1 is fastest but lowest quality
- complexity=5~8 may still encode in real-time on nRF5340
- **Recommendation**: Benchmark quality at complexity 5 and 10; select the highest value the CPU can sustain

**Opus Application Type**:
- The firmware currently uses `OPUS_APPLICATION_AUDIO` (not VOIP), chosen to preserve fricatives for STT.
- `VOIP`: Optimized for voice calls, may over-compress high frequencies
- `AUDIO`: Preserves more spectral detail, better for transcription
- `RESTRICTED_LOWDELAY`: Ultra-low latency, not applicable
- **Recommendation**: Keep `AUDIO`; benchmark WER against `VOIP` only if bitrate is reduced.

**SpeexDSP Noise Suppression Level**:
- 30 dB suppression may be overly aggressive, introducing "musical noise" artifacts
- **Recommendation**: Compare 15 dB / 20 dB / 30 dB settings

### 6.3 Optimization Priority

1. **Increase Opus complexity** -> Immediate quality improvement, minimal side effects
2. **Increase Normal mode bitrate** -> Improved fidelity
3. **Tune noise suppression level** -> Avoid over-processing
4. **Switch Opus to AUDIO mode** -> May improve spectral fidelity
5. **Increase Enhanced mode bitrate** -> Only if WER targets are not met

---

## 7. Test Report Template

### 7.1 Single Test Result

```json
{
  "test_id": "S1_normal_near_20260422",
  "firmware_version": "2.0.7",
  "scenario": {
    "id": "S1",
    "name": "Quiet near-field",
    "distance_m": 0.3,
    "ambient_noise_dba": 32.5,
    "speaker_volume_dba": 65.0
  },
  "device_config": {
    "mode": "normal",
    "bitrate": 24000,
    "complexity": 1,
    "channels": 2,
    "dsp_enabled": false
  },
  "metrics": {
    "snr_db": 25.3,
    "stoi": 0.92,
    "pesq": 3.4,
    "thd_percent": 2.1
  },
  "asr": {
    "engine": "whisper-large-v3",
    "language": "zh",
    "wer_percent": 5.2,
    "reference_text": "今天天气很好，我们去公园散步吧。",
    "transcribed_text": "今天天气很好，我们去公园散步吧。"
  },
  "verdict": {
    "passed": true,
    "failed_metrics": []
  }
}
```

### 7.2 Summary Report

| Scenario | Mode | SNR | STOI | PESQ | WER(CN) | WER(EN) | Result |
|----------|------|-----|------|------|---------|---------|--------|
| S1 Quiet near-field | Normal | -- | -- | -- | -- | -- | -- |
| S1 Quiet near-field | Enhanced | -- | -- | -- | -- | -- | -- |
| S2 Quiet far-field | Normal | -- | -- | -- | -- | -- | -- |
| S2 Quiet far-field | Enhanced | -- | -- | -- | -- | -- | -- |
| S3 Quiet ultra-far (2m) | Normal | -- | -- | -- | -- | -- | -- |
| S3 Quiet ultra-far (2m) | Enhanced | -- | -- | -- | -- | -- | -- |
| S3a Quiet ultra-far (3m) | Normal | -- | -- | -- | -- | -- | -- |
| S3a Quiet ultra-far (3m) | Enhanced | -- | -- | -- | -- | -- | -- |
| S4 Office | Normal | -- | -- | -- | -- | -- | -- |
| S4 Office | Enhanced | -- | -- | -- | -- | -- | -- |

> Fields marked `--` are to be filled after actual testing.

---

## 8. Quick Verification (No Specialized Equipment)

If a sound level meter and calibrated speaker are not available, use these simplified methods:

### 8.1 Noise Floor Test

1. In a quiet room, place the device on a desk with no sound playing
2. Start recording for 10 seconds
3. Export the file and decode to WAV
4. Inspect the waveform in Audacity or Python; confirm silent segment amplitude < -40 dBFS

### 8.2 Speech Clarity Quick Test

1. At normal distance (0.5-1m), face the device and read the Chinese standard corpus
2. Export the recording and transcribe with Whisper
3. Manually compare transcription against the reference text
4. Target: Chinese WER <= 8%, English WER <= 5%

### 8.3 Mode Comparison

Record the same speech in both Normal and Enhanced modes under identical conditions, then compare:
- Listening difference (subjective)
- WER difference (objective)
- Spectral difference (Audacity spectrogram view)
