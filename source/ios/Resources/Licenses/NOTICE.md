# NOTICE: eg2zh-mac-v4 (Mandarin reader zh-v4 with LM decoding, for eg2-transcribe on the Mac and the iPhone)

**中文摘要：** 本包**可以商用**。v4 的中文 reader 和语言模型都按 **CC BY-SA 4.0** 许可：可以用于商业产品，可以转给别人、
公开发布，但要**署名**（保留本文件、`reader_zh/DATA_LICENSES.json` 和 `lm/LM_NOTICE.md`），并且改编后再发布时也用 CC BY-SA 4.0。

1. v4 reader 是**从头重新训练的**，训练数据**只用明确允许商用的语料**（下表，共 721.8 小时、519,206 句真实录音），
   再加上 238.2 小时用 Qwen3-TTS（Apache-2.0）朗读中文维基百科句子（CC BY-SA 3.0）合成的语音。
   要求“同样方式共享”的是 AliMeeting、ASCEND（CC BY-SA 4.0）和维基百科的文字（CC BY-SA 3.0），所以 reader 用 CC BY-SA 4.0。
2. **语言模型** `lm/lm_zh_char.eg2lm` 也只从允许商用的文字统计，许可同样是 CC BY-SA 4.0（详见 `lm/LM_NOTICE.md`）。
3. 本包**只做离线转写**，不含云端纠错。
4. YODAS 的 1,405 个视频我们只有链接，没有作者名字，所以只能按链接署名（见下文“已知的限制”）。

包里没有任何训练音频或训练文本本身，也没有训练权重 `reader.pt`。包里唯一的音频和文本是长录音验收包 `longaudio_kit/`：
AISHELL-1 **test**（测试集，Apache-2.0）6 位说话人的录音和标准文本，署名见下文。

Commercial use is allowed under CC BY-SA 4.0 (attribution, share-alike). Keep this file, `reader_zh/DATA_LICENSES.json`
and `lm/LM_NOTICE.md` with the reader and the LM. The details follow.

## What is in this package, and where it comes from

| Path | What | Origin and licence |
|---|---|---|
| `mac/eg2-transcribe-zh-lm.patch` | Cumulative patch of the eg2-transcribe app: the Mandarin changes + LM decoding (9 Swift files changed, 5 new: `ios/Sources/Pipeline/LM/{EG2LM,CTCLMDecoder,LogAddTable,DecodeSetup}.swift`, `ios/Sources/SelfTest/LMCheck.swift`). Byte-identical to the v3c-lm and v3b-lm packages' patch | Modifies https://github.com/john-rocky/eg2-transcribe at commit `e6b7d5df02fcfe940c194d00ad5d055f958b9c6c` (Apache-2.0, `LICENSE.eg2-transcribe`); the changes are written for this port and are offered under Apache-2.0 |
| `mac/assemble_model_folder.sh` | Builds the app's model folder on the Mac; checks and copies the LM; a reader without `lm_decode` is assembled as before | Written for this port |
| `mac/set_decode_mode.sh` | Shows or sets a model folder's default decoding (`lm` / `greedy`) | Written for this port |
| `mac/bench_speed_mac.sh` | Optional speed comparison on the Mac (our app greedy and with the LM, whisper.cpp small, sherpa-onnx SenseVoice-Small) | Written for this port; the tools and models it downloads keep their own licences and are not part of this package |
| `mac/STEPS.md`, `mac/IPHONE_STEPS.md` | Step-by-step guides (Chinese) for the Mac and the iPhone | Written for this port |
| `reader_zh/` | Mandarin character reader **zh-v4**, version string `zh-v4-lm`: `reader_config.json` (window contract 48, 49, `lm_decode` = the LM decoder's settings, `cer_lm`), `vocab.txt` (7,067 characters), `DATA_LICENSES.json` (every training corpus with source, revision, hours and licence, and an `lm` entry), `cer_lm_v4.json` (greedy and LM decoding results), `coreai/eg2_reader_zh_fp16_T750.aimodel` (Core AI bundle, fp16, attention band +-128, **6 outputs**: 3 greedy outputs plus the top-16 candidates with log-probabilities and the blank log-probability) and `coreai/export_eg2_reader_zh_T750.json` (export record, gates PASS) | Made by this port; CC BY-SA 4.0 (training data below) |
| `lm/lm_zh_char.eg2lm` (+ `lm_zh_char.json`, `SHA256SUMS`, `LM_NOTICE.md`) | Character 3-gram language model for LM decoding, and its build / leakage / check record | Estimated by this port from commercial-use text only (below); CC BY-SA 4.0 (`lm/LM_NOTICE.md`) |
| `fixtures/lm/` | Test data of `--selftest lmcheck`: a tiny LM (`tiny.eg2lm`, a few thousand sentences of the same LM text, same terms as the LM), LM queries with expected values, 95 decoding cases (the v4 bundle graph's top-16 outputs on AISHELL-1 dev / AliMeeting eval near utterances and multi-window streams, synthetic cases, with the decoder's expected output) and window plans | Made by this port; no audio, no reference transcripts |
| `longaudio_kit/` | Long-audio acceptance kit: 6 recordings (16 kHz mono WAV) and their transcripts (`*.truth.txt`), `utterances.tsv`, `kit_meta.json`, the expected results of our CPU replica (`expected/`: greedy and LM decoding) and `run_kit_mac.sh` | Audio and transcripts: AISHELL-1 test set, Apache-2.0 (below; licence text `longaudio_kit/LICENSE.AISHELL-1.Apache-2.0.txt`). Expected transcripts and the script: made by this port |
| `evidence_v4/` | The scoring rules written before scoring (`RETRAIN_MUST_READ.md` excerpt and amendments), the dev decision, the test and long-audio results (error counts only, no text), the export summary and the fixture record | Made by this port |
| `reader_train/export_coreai_topk.py` | The script that exported the 6-output bundle (imports `export_coreai.py` of this project) | Written for this port (code lineage of `reader_train/`: below) |
| `LICENSE.eg2-transcribe` | Apache License 2.0 text of eg2-transcribe | Copied unchanged from that repository at `e6b7d5d` |
| `SHA256SUMS` | SHA-256 of every other file of the package | Made by this port |

The reader is a 6-layer transformer encoder (25,008,284 parameters; arch a, d_model 512) with a learned linear CTC
head over 7,067 characters (7,068 classes with the blank). It reads the audio soft tokens of the EmbeddingGemma 2 encoder.
**zh-v4 is arm A_w_s30 of the v4 retrain**: arm A was trained from scratch (no weights of
any earlier reader) on the real speech of the table below; zh-v4 then continued from arm A's best checkpoint for 10 more
epochs on the same real speech plus 238.2 h of synthetic speech (fresh optimizer, peak learning rate 1.5e-4, cosine over
10 epochs). The training code (`reader_train/` of this project) started as a copy of `reader/train/` of
eg2-transcribe at `e6b7d5d` (Apache-2.0) and was adapted for Mandarin.

The Core AI bundle was exported with `export_coreai_topk.py` (coreai-torch 0.4.1, coreai-core 1.0.0b2; the same script,
image and flags as the v3c-lm export): the greedy graph plus a tail that returns the top-16 characters per token (tie-safe,
logit descending, ties by smaller id) with their log-probabilities over the 7,068 classes and the blank log-probability.

The bundle's `metadata.json` `license` field states the terms directly: CC BY-SA 4.0 (trained on CC BY-SA 4.0 data:
AliMeeting, ASCEND; and on speech synthesized from CC BY-SA 3.0 Wikipedia text), attributions in NOTICE.md and
DATA_LICENSES.json, code lineage Apache-2.0 (eg2-transcribe), input EmbeddingGemma 2 audio soft tokens (Apache-2.0, Gemma
Prohibited Use Policy).

Identities (SHA-256):

- `reader_zh/coreai/eg2_reader_zh_fp16_T750.aimodel/main.mlirb`: `662ffddb001a44bcdbb09db9c3e03096381bdf0d4b5142690d52898cf4e13cd4`
- `reader_zh/vocab.txt`: `bac737f193ccceeba931e065f66eed70765707b0b7837bebe9a87584d1c6ba6c`
- `lm/lm_zh_char.eg2lm`: `3dd72e35359da38e61d09d4284ad0ff74515e6fc56ac27dd60df9020eadfef0d` (28,613,472 bytes)
- `fixtures/lm/tiny.eg2lm`: `034a2363110b564787f90fd680f3f52eaca8f3cf6ccfa06f0af181b63b9976f7`
- `mac/eg2-transcribe-zh-lm.patch`: `f65e310acc5d3c15904b7b80670b1084d60306cf2710b0acc743c9e9cddae346`
- `reader.pt` of zh-v4 (the weights the bundle was exported from; **not included**): `c1d9e4f0a98eb5355adeda59abd484530edb4f5f587d2f0d4786d7419762f8ce`

**Not included, downloaded on the Mac by `assemble_model_folder.sh`:** the EmbeddingGemma 2 audio encoder
(`eg2_audio_fp16_T3000.aimodel`), `pipeline.json`, `mel_filters.bin` and that repository's `LICENSE`/`NOTICE`. They come from
https://huggingface.co/mlboydaisuke/EmbeddingGemma-2-Transcribe-CoreAI at revision
`76865ae46793e05617c2a7420454b0c7eb8541a4`. The licence on that model card is Apache-2.0. EmbeddingGemma 2 deployments must
follow the Gemma Prohibited Use Policy (https://ai.google.dev/gemma/prohibited_use_policy). The script stores the licence
files in the model folder's `licenses/`.

## Training data of the zh-v4 reader

Real speech: 721.8 hours, 519,206 utterances, every corpus permitted for commercial use. The full record, with sources,
revisions and hours kept, is `reader_zh/DATA_LICENSES.json`.

| Corpus | Licence | Commercial use |
|---|---|---|
| AISHELL-1 train (OpenSLR SLR33, https://www.openslr.org/33/) | Apache-2.0 | yes |
| AISHELL-3 (OpenSLR SLR93, https://www.openslr.org/93/) | Apache-2.0 | yes |
| THCHS-30 (OpenSLR SLR18, https://www.openslr.org/18/) | Apache-2.0 | yes |
| Common Voice zh-CN and zh-TW (Mozilla) | CC0-1.0 | yes |
| CSS10 Chinese | CC0-1.0 | yes |
| FLEURS cmn (Google) | CC BY 4.0 | yes, with attribution |
| YODAS_OWSMv4 zho | CC BY 3.0 | yes, with attribution (see "Known limitations") |
| AliMeeting Train, near-field headset channels (OpenSLR SLR119, https://www.openslr.org/119/) | CC BY-SA 4.0 | yes, with attribution and share-alike |
| ASCEND | CC BY-SA 4.0 | yes, with attribution and share-alike |

Synthetic speech (only in the final 10 epochs): 133,091 clips, 238.2 hours.

| Part | What | Licence |
|---|---|---|
| Text | Sentences of Chinese Wikipedia, `wikimedia/wikipedia` 20231101.zh (Hugging Face) | CC BY-SA 3.0; authors: the Wikipedia contributors |
| Voices | Qwen3-TTS-12Hz-1.7B-VoiceDesign and Qwen3-TTS-12Hz-1.7B-CustomVoice (Qwen team, Alibaba), run offline from the published weights | Apache-2.0 (model weights) |
| Check | Every clip was transcribed back with SenseVoiceSmall (FunAudioLLM); a clip was kept only when its toneless-pinyin error rate against the text was at most 0.10 and its speaking rate 2 to 9 characters per second | SenseVoiceSmall was used as a tool only; nothing of it is in the reader |

The synthetic audio and the Wikipedia sentences are not included in this package.

What this means:

- **Commercial use is allowed** under CC BY-SA 4.0. The share-alike terms come from AliMeeting and ASCEND (CC BY-SA 4.0)
  and from the Wikipedia text the synthetic speech reads (CC BY-SA 3.0; adaptations may use a later version).
- **No audio or transcripts of the training data are included.** The raw archives and derived caches stay in private
  storage. `vocab.txt` is only the list of the 7,067 characters the reader can write. The evaluation files hold only error
  counts and rates. The LM files are statistics estimated from text (`lm/LM_NOTICE.md`); they contain no sentences.
- **Keep the notices together.** Wherever the reader or the LM is copied (also inside a model folder or an app), keep
  this `NOTICE.md`, `reader_zh/DATA_LICENSES.json` and `lm/LM_NOTICE.md` with it.
- Shared adaptations of the reader or the LM carry CC BY-SA 4.0.

### Known limitations of the attribution

- **YODAS_OWSMv4 zho**: the dataset gives, per clip, the YouTube video it comes from but not the name of the video's
  author. The record lists the 1,405 video URLs (`YODAS_VIDEOS.tsv` in this package: video id, URL and clips used, one line per video); author names are not available to us. The
  attribution is therefore "YODAS (CC BY 3.0), the creators of the 1,405 YouTube videos listed".
- **ASCEND** and the other corpora are credited by their dataset papers below; individual speakers are not named by any
  of them.

### Creators and citations

- AISHELL-1: Beijing Shell Shell Technology Co., Ltd.; H. Bu et al., "AISHELL-1: An Open-Source Mandarin Speech Corpus
  and A Speech Recognition Baseline", O-COCOSDA 2017.
- AISHELL-3: Beijing Shell Shell Technology Co., Ltd.; Y. Shi et al., "AISHELL-3: A Multi-speaker Mandarin TTS Corpus
  and the Baselines", arXiv:2010.11567 (2020).
- THCHS-30: Center for Speech and Language Technologies, Tsinghua University; D. Wang and X. Zhang, "THCHS-30: A Free
  Chinese Speech Corpus", arXiv:1512.01882 (2015).
- Common Voice: Mozilla; R. Ardila et al., "Common Voice: A Massively-Multilingual Speech Corpus", LREC 2020 (CC0,
  credited as a courtesy).
- CSS10: K. Park and T. Mulc, "CSS10: A Collection of Single Speaker Speech Datasets for 10 Languages", Interspeech 2019
  (CC0, credited as a courtesy).
- FLEURS: Google; A. Conneau et al., "FLEURS: Few-shot Learning Evaluation of Universal Representations of Speech",
  IEEE SLT 2022.
- YODAS: X. Li et al., "YODAS: Youtube-Oriented Dataset for Audio and Speech", IEEE ASRU 2023; the OWSM v4 release of
  it by the OWSM project (Y. Peng et al.); the creators of the 1,405 YouTube videos used.
- AliMeeting: Alibaba DAMO Academy and AISHELL; F. Yu et al., "M2MeT: The ICASSP 2022 Multi-Channel Multi-Party
  Meeting Transcription Challenge", ICASSP 2022.
- ASCEND: H. Lovenia et al., "ASCEND: A Spontaneous Chinese-English Dataset for Code-switching in Multi-turn
  Conversation", LREC 2022.
- Wikipedia: the Wikipedia contributors, Chinese Wikipedia (https://zh.wikipedia.org/), via the Hugging Face dataset
  `wikimedia/wikipedia` (20231101.zh), CC BY-SA 3.0.
- Qwen3-TTS: the Qwen team, Alibaba Cloud; Qwen3-TTS-12Hz-1.7B-VoiceDesign and -CustomVoice, Apache-2.0.

## The language model (`lm/lm_zh_char.eg2lm`)

- **What:** a character 3-gram model (interpolated modified Kneser-Ney), in this port's `eg2lm` v1 format (read
  memory-mapped by the app). Used by the app's LM decoding: CTC prefix beam search over the reader's top candidates with
  shallow fusion (`reader_config.json` `lm_decode`). It is a new file, not the v3c-lm LM.
- **Estimated from:** the transcripts of the zh-v4 reader's real-speech training corpora, all permitted for commercial use (397,982 sentences, 7.70 M characters after leak removal and deduplication; candidate L1). Every sentence equal or near-equal to a reference of AISHELL-1 dev or test or
  AliMeeting eval or test near was removed, then duplicates. Details: `lm/LM_NOTICE.md`, `lm/lm_zh_char.json`.
- **Licence:** CC BY-SA 4.0, commercial use allowed (`lm/LM_NOTICE.md`). The attributions above apply to it as well.
  The same holds for `fixtures/lm/tiny.eg2lm`.
- **Decoder settings** (alpha 0.5, beta 1.5, beam 12, top-8 candidates, candidates below log-probability -6
  ignored, frames with P(blank) > 0.99 skipped, LM context reset after 25 such frames in a row). The reader training
  method, the LM (two candidates) and alpha / beta (a 3 x 3 grid) were chosen on AISHELL-1 dev and AliMeeting eval near
  only, by rules written before scoring (`evidence_v4/`). The test sets were then scored once.

## The long-audio kit (`longaudio_kit/`): AISHELL-1 test audio, Apache-2.0

The kit redistributes part of the **AISHELL-1 test set** (OpenSLR SLR33, https://www.openslr.org/33/, Apache License 2.0;
creator Beijing Shell Shell Technology Co., Ltd.; H. Bu et al., O-COCOSDA 2017). The copy used is the Hugging Face dataset
`knoveleng/aishell1-mandarin` at revision `c6dde006238091dc7c81cf5888208140bba33cba`. The licence text is
`longaudio_kit/LICENSE.AISHELL-1.Apache-2.0.txt`.

- Speakers S0765, S0769, S0903, S0904, S0906 and S0907. For each, the speaker's consecutive test utterances in dataset order,
  from the first, until at least 270 s: 365 utterances, 1,632.9 s and 5,025 characters in all. Their ids are in
  `utterances.tsv`.
- **Modification (Apache-2.0 §4(b)):** each speaker's utterance waveforms were concatenated, unchanged sample for sample and
  with nothing in between, into one 16 kHz mono 16-bit WAV. Each `*.truth.txt` holds the utterances' AISHELL-1
  transcripts, one per line, with whitespace removed.
- `expected/` holds transcripts and error counts that the v4 reader produced from this audio on CPU: greedy and LM
  decoding (zh-v4_48_49, zh-v4-lm_48_49).
- The recordings are the same as in the v3c and v3c-lm packages (made by `make_kit.py`); the v4 expected results were
  made by one Hugging Face Job (`kit_v4`, CPU) from the v3c kit job's float16 soft tokens (the encoder output, independent of the reader); record `evidence_v4/kit_v4_results.json`.

## Evaluation data (scored, never trained on)

- AISHELL-1 dev and test (OpenSLR SLR33, Apache-2.0). AISHELL-1 dev and AliMeeting eval near were used to pick the best
  epoch, to choose between the v4 training methods, to choose the LM and the decoder settings.
- AliMeeting Eval and Test, near-field headset channels (OpenSLR SLR119, CC BY-SA 4.0).

Results with LM decoding (per utterance, band 128, the reader in fp32; test sets scored once; `reader_zh/cer_lm_v4.json`):

- AISHELL-1 test: zh-v4 greedy 6.76 % -> zh-v4 + LM 5.49 %.
- AliMeeting test near: 13.54 % -> 12.46 %.
- The 6 kit recordings through the CPU replica of the app's path: 4.30 % -> 3.48 %.

These are not Mac or iPhone measurements. The LM text includes AISHELL-1 train transcripts (news, the domain of AISHELL-1
test); test sentences and near-equal sentences were removed from it.

For reference, the earlier non-commercial zh-v3c-lm (trained on about 1,630 hours including CC BY-NC-ND 4.0 corpora)
scored 4.88 % / 11.51 % with its LM on the same two test sets. Similarly sized open models on identical audio, one
normalizer and one scorer for every system (`compare_baselines.py score`, greedy unless noted): SenseVoice-Small
3.00 % / 7.16 %; Whisper-small greedy 10.96 % / 22.75 %; Whisper-small beam 5 10.05 % / 22.52 %. Speed on the Mac and the
iPhone has not been measured yet.
