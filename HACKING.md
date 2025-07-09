# HACKING.md

## Contributing Extensions to GPU Video Converter

This guide will help you extend the project with new formats, codecs, filters, hardware support, CLI options, and configuration keys. It is aimed at both new and experienced contributors.

---

## Table of Contents
- [Project Structure Overview](#project-structure-overview)
- [Adding a New Input/Output Format](#adding-a-new-inputoutput-format)
- [Adding a New Video or Audio Codec](#adding-a-new-video-or-audio-codec)
- [Adding a New Video Filter](#adding-a-new-video-filter)
- [Adding New Hardware Detection/Support](#adding-new-hardware-detectionsupport)
- [Adding a New CLI Option](#adding-a-new-cli-option)
- [Adding a New Config Key](#adding-a-new-config-key)
- [Testing Your Changes](#testing-your-changes)
- [Best Practices](#best-practices)

---

## Project Structure Overview

```
video_conv/
├── config/
│   └── defaults.conf         # Main config (formats, codecs, thresholds)
├── lib/
│   ├── utils.sh              # Logging, helpers
│   ├── hardware.sh           # Hardware detection
│   ├── encoders.sh           # Encoder selection/config
│   ├── video_analysis.sh     # Video file analysis
│   ├── audio_processing.sh   # Audio conversion
│   └── video_filters.sh      # Video filter chain
├── cvrt.sh                  # Main script (argument parsing, orchestration)
├── dev-tools.sh             # Development tools
└── README.md
```

---

## Adding a New Input/Output Format

1. **Edit `config/defaults.conf`:**
   - Add the new extension to `SUPPORTED_INPUT_EXTENSIONS` or `SUPPORTED_OUTPUT_FORMATS`.
   ```bash
   readonly -a SUPPORTED_INPUT_EXTENSIONS=(
       "mkv" "mp4" "avi" "mov" "webm" "flv" "ts" "m2ts" "newformat"
   )
   ```
2. **Update output container mapping if needed:**
   ```bash
   CONTAINER_FORMATS[newformat]="newcontainer"
   ```
3. **No code changes needed** if the format is supported by ffmpeg.

---

## Adding a New Video or Audio Codec

1. **Edit `config/defaults.conf`:**
   - Add to `SUPPORTED_VIDEO_CODECS` or `SUPPORTED_AUDIO_CODECS`.
2. **Edit `lib/encoders.sh`:**
   - Add a new case to the relevant encoder function (e.g., `get_software_arguments`, `get_nvenc_arguments`).
   - Example template:
   ```bash
   get_software_arguments() {
       # ... existing code ...
       case "$codec" in
           newcodec)
               sw_args+=("-c:v" "libnewcodec")
               ;;
           # ...
       esac
   }
   ```
3. **Update README and help output** to document the new codec.

---

## Adding a New Video Filter

1. **Edit `lib/video_filters.sh`:**
   - Add a new filter option in `build_video_filters()`.
   - Example:
   ```bash
   if [[ "${NEWFILTER:-false}" == "true" ]]; then
       filters+=("newfilter=params")
   fi
   ```
2. **Add a CLI option in `cvrt.sh`** (see below).
3. **Document in README and `--list-filters`.**

---

## Adding New Hardware Detection/Support

1. **Edit `lib/hardware.sh`:**
   - Add detection logic in `detect_gpu_hardware()` or a new function.
   - Add new hardware flags/capabilities as needed.
2. **Update encoder selection logic** if the new hardware supports special encoders.
3. **Document in README.**

---

## Adding a New CLI Option

1. **Edit `cvrt.sh`:**
   - Add a new case in `parse_arguments()`:
   ```bash
   --newoption)
       NEWOPTION=true
       log_info "New option enabled"
       shift
       ;;
   ```
   - Add to `show_usage()` help text.
2. **If it affects filters or encoders,** pass the variable to the relevant module.
3. **Document in README.**

---

## Adding a New Config Key

1. **Edit `config/defaults.conf`:**
   - Add the new key and a comment.
2. **Reference it in code** (e.g., in `cvrt.sh` or a module) as needed.
3. **Document in README or CONFIG.md.**

---

## Testing Your Changes

- Use `./dev-tools.sh all` to run all checks.
- Use `./cvrt.sh --list-formats`, `--list-codecs`, and `--help` to verify discoverability.
- Add test files and try new options on sample videos.
- If adding a new filter or codec, test with a small video and check output quality.

---

## Best Practices

- **Keep changes modular:** One feature per commit/PR.
- **Update documentation** for every new feature.
- **Add comments** at extension points.
- **Test on multiple platforms** if possible (Linux, macOS).
- **Ask for help:** If unsure, open an issue or PR for discussion.

---

Happy hacking! 🎬 