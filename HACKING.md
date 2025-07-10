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
├── ci-local.sh              # Local CI checks
├── dev-tools.sh             # Development tools
├── test_argument_parsing.sh # Argument parsing tests
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

**Note:** Video filters are automatically integrated into the main encoding process. The `build_video_filters()` function constructs filter chains that are passed to ffmpeg commands in `lib/audio_processing.sh`. No additional integration code is needed.

---

## Adding New Hardware Detection/Support

1. **Edit `lib/hardware.sh`:**
   - Add detection logic in `detect_gpu_hardware()` or a new function.
   - Add new hardware flags/capabilities as needed.
2. **Update encoder selection logic** if the new hardware supports special encoders.
3. **Document in README.**

---

## Subtitle and Metadata Integration

The script now properly integrates subtitle and metadata handling into the main encoding process:

### Video Filters Integration

- **`build_video_filters()`** constructs video filter chains based on CLI options
- **`build_subtitle_filters()`** handles subtitle processing (burn, extract, none, copy)
- **`build_metadata_args()`** handles metadata processing (strip, minimal, copy)
- **`build_performance_args()`** adds performance optimization arguments

### Integration Points

All encoding functions in `lib/audio_processing.sh` now call these builder functions:

```bash
# Build video filters
local -a video_filters
if ! build_video_filters "$input_file" video_filters; then
    log_warn "Failed to build video filters, proceeding without filters"
fi

# Build subtitle filters
local -a subtitle_filters
build_subtitle_filters "$input_file" subtitle_filters

# Build metadata arguments
local -a metadata_args
build_metadata_args metadata_args

# Build performance arguments
local -a perf_args
build_performance_args perf_args

# Pass all arguments to ffmpeg
ffmpeg "${ffmpeg_inputs[@]}" \
       "${map_args[@]}" \
       "${video_filters[@]}" \
       "${subtitle_filters[@]}" \
       "${metadata_args[@]}" \
       "${perf_args[@]}" \
       "${encoder_args[@]}" \
       -c:a copy \
       -y "$output_file"
```

### Filter Compatibility

- **`validate_filter_compatibility()`** checks if filters are compatible with the selected encoder
- Hardware encoders (NVENC, QSV, VAAPI) may have limited filter support
- Software encoding supports all filters

**Enhanced Validation Features:**

The function now provides three levels of feedback:

1. **Compatible (return 0):** No issues detected
2. **Suboptimal (return 2):** Filters may not work optimally, but encoding proceeds with warnings
3. **Fatal (return 1):** Known problematic combination that will likely fail

**User Feedback:**

- **Visual warnings** with clear formatting and emojis
- **Specific recommendations** for each compatibility issue
- **Actionable advice** (e.g., "Use --cpu for software encoding")
- **Fatal combinations** cause the script to abort with clear error messages

**Example Output:**
```
⚠️  WARNING: Suboptimal filter/encoder combination detected
==========================================================
  • Deinterlacing (yadif) may not work optimally with NVENC
  • Denoising (nlmeans) may not work optimally with NVENC

These filters may not work as expected with NVENC.
Consider using --cpu for software encoding if you need these filters.
```

**Known Limitations:**

- **NVENC:** Limited support for complex filters (yadif, nlmeans, unsharp, subtitles)
- **QSV:** Limited support for nlmeans and subtitle burning
- **VAAPI:** Limited support for nlmeans and subtitle burning
- **SOFTWARE:** Full support for all filters

---

## Adding a New CLI Option

1. **Edit `cvrt.sh`:**
   - Add a new case in `parse_arguments()` for both getopt and legacy parsing:
   ```bash
   --newoption)
       NEWOPTION=true
       log_info "New option enabled"
       shift
       ;;
   ```
   - Add to `show_usage()` help text.
   - If the option requires a value, add validation in `validate_parsed_arguments()`.
2. **If it affects filters or encoders,** pass the variable to the relevant module.
3. **Document in README.**
4. **Test with `./test_argument_parsing.sh`** to ensure order-independent parsing works.

**Note:** The argument parsing system supports both `getopt` (preferred) and legacy parsing (fallback). Options are order-independent and automatically validated.

---

## Adding a New Config Key

1. **Edit `config/defaults.conf`:**
   - Add the new key and a comment.
2. **Reference it in code** (e.g., in `cvrt.sh` or a module) as needed.
3. **Document in README or CONFIG.md.**

---

## Configuration Overrides and Customization

### User Configuration Overrides

The script supports user customization through `config/custom.conf`. This file is automatically sourced after `defaults.conf`, allowing users to override various settings.

#### Overridable Arrays and Variables

The following arrays can be overridden in `custom.conf`:

- `SUPPORTED_INPUT_EXTENSIONS` - Input file formats to process
- `SUPPORTED_OUTPUT_FORMATS` - Output container formats
- `SUPPORTED_VIDEO_CODECS` - Video codecs (order matters for auto-selection)
- `SUPPORTED_AUDIO_CODECS` - Audio codecs
- `CONTAINER_FORMATS` - Container format mappings

#### Example custom.conf

```bash
#!/bin/bash
# Override supported input extensions
SUPPORTED_INPUT_EXTENSIONS=(
    "mkv" "mp4" "avi" "mov" "webm" "flv" "ts" "m2ts" "3gp" "ogv"
)

# Override supported output formats
SUPPORTED_OUTPUT_FORMATS=(
    "mkv" "mp4" "mov" "webm" "avi"
)

# Change video codec preference order
SUPPORTED_VIDEO_CODECS=(
    "h264"   # Prefer H.264 over HEVC
    "hevc"   # H.265
    "av1"    # AV1
    "vp9"    # VP9
)

# Add new container format mappings
declare -A CONTAINER_FORMATS
CONTAINER_FORMATS[mkv]="matroska"
CONTAINER_FORMATS[mp4]="mp4"
CONTAINER_FORMATS[mov]="mov"
CONTAINER_FORMATS[webm]="webm"
CONTAINER_FORMATS[avi]="avi"
CONTAINER_FORMATS[3gp]="3gpp"
```

#### Environment Variable Overrides

Many settings can also be overridden via environment variables:

```bash
export CVRT_QUALITY=20           # Lower CRF for higher quality
export CVRT_STEREO_BITRATE="256k" # Higher audio bitrate
export CVRT_MAX_BITRATE="100M"    # Higher max bitrate
export CVRT_BUFFER_SIZE="200M"    # Larger buffer
```

#### Readonly vs Overridable Variables

- **Readonly variables** (marked with `readonly`) cannot be overridden and are meant to be constant.
- **Overridable arrays** are declared without `readonly` initially, sourced from `custom.conf` if present, then made readonly to prevent further modification.

### Adding New Overridable Settings

When adding new configuration options:

1. **For truly constant values:** Use `readonly` immediately
2. **For user-overridable values:** Declare without `readonly`, allow `custom.conf` override, then make readonly
3. **For environment-overridable values:** Use the pattern `readonly VAR=${ENV_VAR:-default_value}`

Example:
```bash
# Constant - never override
readonly REQUIRED_TOOLS=("ffmpeg" "ffprobe")

# User-overridable - can be changed in custom.conf
SUPPORTED_FORMATS=("mkv" "mp4")
# ... custom.conf is sourced here ...
readonly -a SUPPORTED_FORMATS

# Environment-overridable - can be set via env vars
readonly QUALITY=${CVRT_QUALITY:-24}
```

---

## Testing Your Changes

### Local Development Workflow

1. **Run local CI checks:**
   ```bash
   ./ci-local.sh
   ```

2. **Use development tools:**
   ```bash
   ./dev-tools.sh all
   ```

3. **Test argument parsing:**
   ```bash
   ./test_argument_parsing.sh
   ```

4. **Verify functionality:**
   - Use `./cvrt.sh --list-formats`, `--list-codecs`, and `--help` to verify discoverability.
   - Add test files and try new options on sample videos.
   - If adding a new filter or codec, test with a small video and check output quality.

### Pre-commit Hooks

The project includes pre-commit hooks that automatically run `./ci-local.sh` before each commit. This ensures code quality and prevents broken commits.

---

## Best Practices

- **Keep changes modular:** One feature per commit/PR.
- **Update documentation** for every new feature.
- **Write self-descriptive code:** Minimize comments, use clear function and variable names.
- **Test on multiple platforms** if possible (Linux, macOS).
- **Use the local CI system:** Always run `./ci-local.sh` before committing.
- **Test argument parsing:** Ensure new CLI options work in any order.
- **Ask for help:** If unsure, open an issue or PR for discussion.

---

Happy hacking! 🎬 