# Model Files

This directory previously held bundled model files. The Gemma 4 E2B model is
now downloaded at runtime by the app's local `ModelDownloader` service from
Hugging Face.

The downloaded model is stored at:
`~/Library/Application Support/LiteRTLM/Models/`

The app stores a companion metadata JSON file beside the model. That metadata
records the Hugging Face commit used for the download so Settings can detect
when the installed model is older than the app's current model manifest.

## Notes

- The `.litertlm` format is specific to Google's LiteRT-LM inference framework.
- Gemma 4 E2B (Effective 2 Billion parameters) is optimized for edge deployment.
- All inference runs entirely on-device. No data leaves the device.
- The app requires iOS 26+, iPhone 13 Pro+ (6 GB RAM), and the
  `increased-memory-limit` entitlement.
