# LM_NOTICE: lm_zh_char.eg2lm（中文字符语言模型，v4）

**可以商用。** 这个语言模型按 **CC BY-SA 4.0** 许可：可以用于商业产品，可以转给别人、公开发布，但要**署名**
（保留本文件和 `../NOTICE.md`），并且改编后再发布时也用 CC BY-SA 4.0。

- 它只从**允许商用的文字**统计出来，不含 v3c-lm 那些不允许商用的语料（ST-CMDS、Primewords、MagicData-RAMC、MAGICDATA）。
- 它只有统计数字，不含声音，也不含原文句子。
- 这和 v3c-lm、v3b-lm 包里的 `lm/lm_zh_char.eg2lm` **不是同一个文件**：旧文件只能非商业研究用，不能和 v4 的 reader 混用
  （组装脚本会拒绝）。
- `../fixtures/lm/tiny.eg2lm`（同一批文字里的一小部分句子做的小语言模型，只给 `lmcheck` 测试用）的许可和这个文件相同。

**本包用的是 L1**（两个候选语言模型之一；两者在开发集上打平，按事先定好的规则选了更小的 L1）。
- **用了哪些文字**：v4 reader 的真实录音训练数据的转写文本（见下表）。

---

**English.** `lm_zh_char.eg2lm` (SHA-256 `3dd72e35359da38e61d09d4284ad0ff74515e6fc56ac27dd60df9020eadfef0d`, 28,613,472 bytes) is a character 3-gram language model
(interpolated modified Kneser-Ney; eg2lm v1 format) estimated by this port.

**Text (L1):** the transcripts (textnorm_zh-2) of the real-speech training corpora of the v4 reader, all permitted for
commercial use: 397,982 sentences after removing evaluation leaks and duplicates, 7.70 M characters. Unpruned (every n-gram of the text kept).
The file that was scored on the dev and test sets has SHA-256
`685972cffe7b79120d815441ad2d0cdf72739a57c6669fb441ba4e7f80e04d3a`; the shipped file is that file with only its embedded
meta JSON rewritten (its build had stamped the v3 default non-commercial licence string by mistake). The n-gram
sections are byte-identical and 13,034 random queries score identically (`../evidence_v4/lm_relicense.json`).
Perplexity: AISHELL-1 dev 69.7, AliMeeting eval near 42.9.

| Corpus | Licence | Sentences in the LM text |
|---|---|---:|
| AISHELL-1 train (OpenSLR SLR33) | Apache-2.0 | 112,876 |
| AISHELL-3 (OpenSLR SLR93) | Apache-2.0 | 70,308 |
| THCHS-30 (OpenSLR SLR18) | Apache-2.0 | 999 |
| Common Voice zh-CN and zh-TW (Mozilla) | CC0-1.0 | 65,375 |
| CSS10 Chinese | CC0-1.0 | 2,833 |
| FLEURS cmn | CC BY 4.0 | 1,112 |
| YODAS_OWSMv4 zho | CC BY 3.0 | 18,087 |
| AliMeeting train, near-field (OpenSLR SLR119) | CC BY-SA 4.0 | 122,852 |
| ASCEND | CC BY-SA 4.0 | 3,540 |

Text processing: textnorm_zh-2 normalization (the reader's training labels); every sentence equal or near-equal to a
reference of AISHELL-1 dev / test or AliMeeting eval / test near removed (24,047 exact and 1,730
near matches); duplicates removed; every character of the LM text is in `../reader_zh/vocab.txt` (0 unknown characters). The synthetic speech of the v4 reader is not used
as LM text (its sentences are Wikipedia sentences; they enter the LM only in L2, through the Wikipedia text).

**Terms.** CC BY-SA 4.0. The LM is an adaptation of the texts above: CC BY-SA 4.0 (AliMeeting, ASCEND)
 require share-alike; CC BY 4.0
(FLEURS) and CC BY 3.0 (YODAS) require attribution. Keep this file and `../NOTICE.md` (which credits every corpus) with
the LM, also inside a model folder or app. Commercial use is allowed. The file carries these terms in its embedded meta
JSON (`licence`).

**Checks** (`lm_zh_char.json`): L-1 (probabilities of 300 contexts sum to 1 within 1.0e-06; perplexity AISHELL-1 dev 69.7, AliMeeting eval near 42.9) pass; L-2 (22,004 queries equal to an independent ARPA reader within 5.0e-07 in log10) pass; L-3 (n-gram counts equal to the ARPA header, file size) pass. The checks ran on the scored file (685972cffe7b7912...); the shipped file differs from it only in its meta JSON (`../evidence_v4/lm_relicense.json`).

**Decoder settings** (`../reader_zh/reader_config.json` `lm_decode`): alpha 0.5, beta 1.5, beam 12, top-8
candidates, candidates below log-probability -6 ignored, frames with P(blank) > 0.99 skipped, LM context reset after 25
such frames in a row. The LM (L1 or L2) and alpha / beta were chosen on AISHELL-1 dev and AliMeeting eval near only, by a
rule written before the scoring (`../evidence_v4/`).

**Results with the v4 reader** (`../reader_zh/cer_lm_v4.json`; test sets scored once): AISHELL-1 test
6.76 % greedy -> 5.49 % with this LM; AliMeeting test near 13.54 % ->
12.46 %.

**Not shipped:** the ARPA text of this LM, the LM text itself, and the other candidate LM (L2: the L1 text plus 3.54 M Chinese Wikipedia sentences, pruned to 75.7 MB; with the release reader it scored 4.85 % / 10.24 % on the dev sets (mean 7.542 vs 7.529 for L1: a tie within 0.05 points, so the smaller L1 was kept by the rule)), which was
scored on the dev sets only.
