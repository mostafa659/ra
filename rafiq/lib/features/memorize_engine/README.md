# Recitation session

The active on-device backend is the streaming Zipformer2 CTC model run directly through ONNX Runtime. The session controller matches the recognizer's **token labels** against the canonical reference tokenized by the exact `tokens.txt` vocabulary (falling back to normalized Unicode comparison, which the developer overlay labels explicitly), and after each judged ayah asks the frame judge for a per-token confidence/competitor check on the model's own frame posteriors.

The frame judge's thresholds are uncalibrated; the evidence log (`rafiq_evidence.jsonl`) stores every token's scores so they can be tuned on recordings with labelled errors. Token timestamp differences alone must still not be presented as duration grades.

The release workflow builds lightweight arm64 and arm32 APKs with the developer overlay enabled via `RAFIQ_ENABLE_TELEMETRY=true`. The large v3.1 model is a separate `rafiq-model-v3.1-pack` artifact that is imported once in the app and retained across ordinary APK upgrades. Choose only the ABI artifact appropriate for the target phone.
