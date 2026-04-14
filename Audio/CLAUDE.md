# Audio/

Audio capture and encoding.

| File | Description |
|------|-------------|
| **AudioRecorder.swift** | Recording module. AVAudioEngine + installTap for mic capture, AVAudioConverter downsampling to 16kHz/24kHz. Two modes: standard (memory buffer, encode M4A on stop) and streaming (per-chunk PCM16 callback for Realtime API). Detects mic availability and system dictation conflicts |
| **AudioEncoder.swift** | Audio encoding. `encodeToM4A()`: Float32 samples → temp AVAudioFile (AAC 16kHz 24kbps) → read back compressed data. `encodeToWAV()`: manual WAV header (44 bytes + PCM16), fallback for M4A failure. Compression ratio ~20:1 |
