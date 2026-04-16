# Audio/

Audio capture and encoding.

| File | Description |
|------|-------------|
| **AudioRecorder.swift** | Recording module. AVAudioEngine + installTap for mic capture, AVAudioConverter downsampling to 16kHz. Memory-buffered Float32 capture, encoded to M4A (or WAV fallback) on stop. Detects mic availability and system dictation conflicts |
| **AudioEncoder.swift** | Audio encoding. `encodeToM4A()`: Float32 samples → temp AVAudioFile (AAC 16kHz 24kbps) → read back compressed data. `encodeToWAV()`: manual WAV header (44 bytes + PCM16), fallback for M4A failure. Compression ratio ~20:1 |
