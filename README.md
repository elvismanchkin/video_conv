# GPU Video Converter v8.0

A modular, maintainable Bash-based video converter with automatic hardware acceleration detection and optimization. Converts video files to HEVC (H.265) using the best available encoder: NVIDIA NVENC, Intel QSV, AMD VAAPI, or software fallback.

The script features robust command-line argument parsing that works regardless of option order, comprehensive error handling, and automatic fallbacks for maximum compatibility.

## Features

* **Robust CLI Parsing**: Order-independent argument parsing with comprehensive validation
* **Modular Architecture**: Clean separation of concerns across multiple library files
* **Intelligent Hardware Detection**: Automatic detection and scoring of available encoders
* **Multi-Platform GPU Support**:
  - NVIDIA NVENC (RTX/GTX series, AV1 support on newer cards)
  - Intel QSV (integrated and Arc discrete GPUs)
  - AMD VAAPI (APUs and discrete GPUs)
* **Multi-Format Support**: Input: MKV, MP4, AVI, MOV, M4V, WMV, FLV, WebM, TS, MTS, M2TS
* **Multi-Codec Support**: HEVC (H.265), H.264, AV1, VP9 with automatic selection
* **Advanced Processing**: Scaling, deinterlacing, denoising, sharpening filters
* **Subtitle Handling**: Copy, burn, extract, or remove subtitles
* **Metadata Control**: Copy, strip, or minimal metadata handling
* **Configurable Settings**: Environment variable overrides and config files
* **Smart Audio Processing**: Preserves non-5.1 tracks, converts 5.1 to stereo when needed
* **RAM Disk Optimization**: Automatic use of `/dev/shm` when available
* **Comprehensive Error Handling**: Graceful fallbacks and detailed logging
* **10-bit HDR Support**: Hardware-accelerated when supported
* **Local CI Integration**: Pre-commit hooks and local testing scripts

## Project Structure

```
video_conv/
├── config/
│   └── defaults.conf      # Configuration settings
├── lib/
│   ├── utils.sh          # Logging and utility functions
│   ├── hardware.sh       # Hardware detection and capabilities
│   ├── encoders.sh       # Encoder selection and configuration
│   ├── video_analysis.sh # Video file analysis and metadata
│   ├── audio_processing.sh # Audio conversion and encoding
│   └── video_filters.sh  # Video filter chain
├── cvrt.sh              # Main orchestration script
├── ci-local.sh          # Local CI checks
├── dev-tools.sh         # Development utilities
├── test_argument_parsing.sh # Argument parsing tests
└── README.md
```

## Prerequisites

### Required Tools
```bash
ffmpeg ffprobe jq

# For VAAPI support (optional)
libva-utils
```

## Installation

### System-Wide Installation (Recommended)

To make the script available system-wide, create a symlink in a directory that's in your PATH:

```bash
# Option 1: Using /usr/local/bin (requires sudo)
sudo ln -sf /path/to/video_conv/cvrt.sh /usr/local/bin/cvrt

# Option 2: Using user directory (if ~/bin is in PATH)
mkdir -p ~/bin
ln -sf /path/to/video_conv/cvrt.sh ~/bin/cvrt
# Add to ~/.bashrc or ~/.zshrc if not already there:
# export PATH="$HOME/bin:$PATH"

# Option 3: Using Homebrew bin directory (macOS)
ln -sf /path/to/video_conv/cvrt.sh /opt/homebrew/bin/cvrt
```

Replace `/path/to/video_conv/` with the actual path to your script directory.

### Verify Installation

After installation, you can run the script from anywhere:

```bash
cvrt --help
cvrt /path/to/videos
```

The script will automatically locate its configuration and library files regardless of where it's called from.

### Distribution-Specific Setup

**Ubuntu/Debian:**
```bash
sudo apt update && sudo apt install ffmpeg vainfo jq
# AMD: sudo apt install mesa-va-drivers
# Intel: sudo apt install intel-media-va-driver
# NVIDIA: sudo apt install libnvidia-encode
```

**Fedora/RHEL:**
```bash
sudo dnf install ffmpeg libva-utils jq mesa-va-drivers
# AMD: sudo dnf install mesa-va-drivers-freeworld
# Intel: sudo dnf install intel-media-driver
# NVIDIA: sudo dnf install nvidia-driver
```

**Arch Linux:**
```bash
sudo pacman -S ffmpeg libva-utils jq libva-mesa-driver
# Intel: sudo pacman -S intel-media-driver
# NVIDIA: sudo pacman -S nvidia-utils
```

**macOS (Intel):**
```bash
# Install Homebrew if not already installed
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install required tools
brew install ffmpeg jq

# Note: Hardware acceleration limited on Intel Macs
# Software encoding recommended for best quality
```

**macOS (Apple Silicon/ARM):**
```bash
# Install Homebrew if not already installed
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install required tools
brew install ffmpeg jq

# Apple Silicon Notes:
# - Hardware acceleration available through VideoToolbox
# - Excellent performance with software encoding
# - 10-bit HEVC encoding supported natively
# - Consider using --cpu for maximum quality
```

## Usage

### Basic Syntax
```bash
# If installed system-wide
cvrt [OPTIONS] [DIRECTORY]

# If running from script directory
./cvrt.sh [OPTIONS] [DIRECTORY]
```

### Command-Line Options
- `--replace`, `-r`: Replace original files (destructive operation)
- `--debug`, `-d`: Enable detailed debug output
- `--cpu`: Force software encoding (highest quality, slowest)
- `--gpu`: Auto-select best available GPU encoder
- `--nvenc`: Force NVIDIA NVENC encoder
- `--vaapi`: Force AMD/Intel VAAPI encoder
- `--qsv`: Force Intel Quick Sync Video encoder
- `--format`: Specify output format (**must be one of:** mkv, mp4, mov, webm)
- `--codec`: Force video codec (**must be one of:** hevc, h264, av1, vp9)
- `--audio-codec`: Force audio codec (**must be one of:** aac, ac3, opus, flac, mp3)
- `--quality`: Set quality parameter (1-1000, default: 24)
- `--preset`: Set encoding preset (encoder-specific, default: medium)
- `--scale`: Set scaling mode (**must be one of:** none, 1080p, 720p, 480p, 4k, custom)
- `--deinterlace`: Enable deinterlacing (default: disabled)
- `--denoise`: Enable denoising (default: disabled)
- `--sharpen`: Enable sharpening (default: disabled)
- `--subtitles`: Set subtitle mode (**must be one of:** copy, burn, extract, none)
- `--metadata`: Set metadata mode (**must be one of:** copy, strip, minimal)
- `--threads`: Set thread count (0 = auto-detect, default: 0)
- `--list-formats`: List supported output formats
- `--list-codecs`: List supported video/audio codecs
- `--help`, `-h`: Show usage information

### Default Values

**Output Settings:**
- Default output format: `mkv`
- Default video codec: `hevc` (H.265)
- Default audio codec: `aac`
- Default quality parameter: `24` (lower = higher quality)

**Processing Options:**
- Default scaling mode: `none` (no scaling)
- Default deinterlacing: `disabled`
- Default denoising: `disabled`
- Default sharpening: `disabled`
- Default subtitle mode: `copy` (preserve subtitles)
- Default metadata mode: `copy` (preserve metadata)
- Default thread count: `0` (auto-detect)

**Performance Settings:**
- Default stereo bitrate: `192k`
- Default max bitrate: `50M`
- Default buffer size: `100M`
- Default encoding preset: `medium`

### Examples

**Standard conversion (safe, non-destructive):**
```bash
cvrt /media/movies
```

**In-place replacement with debug output:**
```bash
cvrt --replace --debug .
```

**Force CPU encoding for maximum quality:**
```bash
cvrt --cpu /path/to/videos
```

**Auto-select best GPU encoder:**
```bash
cvrt --gpu /media/4k-content
```

**Convert to different format with specific codec (order-independent):**
```bash
cvrt --format mp4 --codec h264 /path/to/videos
cvrt --codec h264 --format mp4 /path/to/videos  # Same result!
cvrt --debug --format mp4 --codec h264 --replace /path/to/videos  # Any order works!
```

**Scale videos to 1080p with deinterlacing:**
```bash
cvrt --scale 1080p --deinterlace /path/to/videos
```

**Process with advanced filters:**
```bash
cvrt --denoise --sharpen --quality 20 /path/to/videos
```

**Handle subtitles and metadata:**
```bash
cvrt --subtitles burn --metadata strip /path/to/videos
```

**Advanced scaling and processing:**
```bash
# Scale to 4K
cvrt --scale 4k --quality 18 /path/to/videos

# Scale to 720p with custom quality
cvrt --scale 720p --quality 22 /path/to/videos

# No scaling (default)
cvrt --scale none /path/to/videos
```

**Subtitle processing options:**
```bash
cvrt --subtitles copy /path/to/videos    # Preserve subtitles (default)
cvrt --subtitles burn /path/to/videos    # Burn subtitles into video
cvrt --subtitles extract /path/to/videos # Extract subtitles to .srt files
cvrt --subtitles none /path/to/videos    # Remove subtitles
```

**Metadata processing options:**
```bash
cvrt --metadata copy /path/to/videos     # Preserve all metadata (default)
cvrt --metadata strip /path/to/videos    # Remove all metadata
cvrt --metadata minimal /path/to/videos  # Keep only essential metadata
```

**Performance tuning:**
```bash
# Use specific thread count
cvrt --threads 8 /path/to/videos

# Auto-detect threads (default)
cvrt --threads 0 /path/to/videos
```

**Running from script directory (if not installed system-wide):**
```bash
./cvrt.sh /media/movies
```

## Configuration

### Default Configuration

The script uses `config/defaults.conf` for all default settings. This file contains:

- Supported input/output formats and codecs
- Quality and performance settings
- Hardware detection thresholds
- Default encoding parameters

### Custom Configuration

You can create a custom configuration file to override default settings. The script supports multiple configuration locations with the following precedence order (highest to lowest priority):

1. **Current working directory** (`./custom.conf`) - for project-specific configs
2. **XDG config directory** (`~/.config/video_conv/custom.conf`) - for user configs
3. **User home directory** (`~/.video_conv.conf`) - legacy location
4. **Script directory** (`config/custom.conf`) - system-wide defaults

**Example setup:**
```bash
# Copy the example file to your preferred location
cp config/custom.conf.example ~/.config/video_conv/custom.conf

# Or create a project-specific config in your video directory
cp config/custom.conf.example ./custom.conf

# Edit to your preferences
nano ~/.config/video_conv/custom.conf
```

**Configuration precedence example:**
- If you have settings in `./custom.conf` (current directory) and `~/.config/video_conv/custom.conf`, the current directory settings will take precedence
- This allows you to have global settings in XDG config and override them for specific projects

#### What You Can Override

**Supported Formats and Codecs:**
- `SUPPORTED_INPUT_EXTENSIONS` - Add/remove input file formats
- `SUPPORTED_OUTPUT_FORMATS` - Add/remove output container formats  
- `SUPPORTED_VIDEO_CODECS` - Change codec preference order
- `SUPPORTED_AUDIO_CODECS` - Add/remove audio codecs
- `CONTAINER_FORMATS` - Add new container format mappings

**Quality and Performance Settings:**
- `QUALITY_PARAM` - Video quality parameter (default: 24, lower = higher quality)
- `STEREO_BITRATE` - Audio bitrate for stereo conversion (default: "192k")
- `MAX_BITRATE` - Maximum video bitrate (default: "50M")
- `BUFFER_SIZE` - Encoding buffer size (default: "100M")
- `DEFAULT_THREADS` - Default thread count (default: 0 = auto-detect)

**Processing Options:**
- `DEFAULT_SCALE_MODE` - Default scaling mode (default: "none")
- `DEFAULT_DEINTERLACE` - Default deinterlacing (default: false)
- `DEFAULT_DENOISE` - Default denoising (default: false)
- `DEFAULT_SHARPEN` - Default sharpening (default: false)
- `DEFAULT_SUBTITLE_MODE` - Default subtitle handling (default: "copy")
- `DEFAULT_METADATA_MODE` - Default metadata handling (default: "copy")

**Hardware Detection Settings:**
- `MIN_RAM_DISK_GB` - Minimum RAM disk size in GB (default: 1)
- `RAM_DISK_PATH` - RAM disk path (default: "/dev/shm")
- `HIGH_COMPLEXITY_THRESHOLD` - High complexity threshold in pixels (default: 8000000)
- `MEDIUM_COMPLEXITY_THRESHOLD` - Medium complexity threshold in pixels (default: 2000000)

**Example custom.conf:**
```bash
#!/bin/bash
# Add support for 3GP and OGV files
SUPPORTED_INPUT_EXTENSIONS=(
    "mkv" "mp4" "avi" "mov" "webm" "flv" "ts" "m2ts" "3gp" "ogv"
)

# Prefer H.264 over HEVC for better compatibility
SUPPORTED_VIDEO_CODECS=(
    "h264"   # H.264 (better compatibility)
    "hevc"   # H.265 (better compression)
    "av1"    # AV1 (newer cards)
    "vp9"    # VP9
)

# Add Vorbis audio codec support
SUPPORTED_AUDIO_CODECS=(
    "aac" "ac3" "opus" "flac" "mp3" "vorbis"
)

# Override quality settings
QUALITY_PARAM=20                    # Higher quality (lower number)
STEREO_BITRATE="256k"              # Higher audio bitrate
MAX_BITRATE="100M"                 # Higher max bitrate
BUFFER_SIZE="200M"                 # Larger buffer

# Enable processing by default
DEFAULT_DEINTERLACE=true           # Enable deinterlacing by default
DEFAULT_DENOISE=true               # Enable denoising by default
DEFAULT_SCALE_MODE="1080p"         # Scale to 1080p by default
```

#### Environment Variables

Many settings can also be overridden via environment variables:

```bash
export CVRT_QUALITY=20           # Lower CRF for higher quality
export CVRT_STEREO_BITRATE="256k" # Higher audio bitrate
export CVRT_MAX_BITRATE="100M"    # Higher max bitrate
export CVRT_BUFFER_SIZE="200M"    # Larger buffer
```

### Configuration Hierarchy

1. **Hardcoded defaults** in `config/defaults.conf`
2. **User overrides** in `config/custom.conf` (if present)
3. **Environment variables** (highest priority)

### Advanced Configuration
Edit `config/defaults.conf` to modify:
- Encoder scoring priorities
- Hardware detection thresholds
- Temporary file management
- Buffer sizes and bitrates

## User Customization

You can override any configuration by creating a `config/custom.conf` file. This file is automatically sourced after `defaults.conf` and can be used to set or override any variable or array.

Example:
```bash
# config/custom.conf
readonly DEFAULT_QUALITY_PARAM=20
readonly SUPPORTED_INPUT_EXTENSIONS=("mkv" "mp4" "mov" "webm")
```

See [HACKING.md](./HACKING.md) for advanced extension guides (adding formats, codecs, filters, hardware, CLI options, and more).

## Hardware-Specific Notes

### AMD Graphics (VAAPI)
- Quality varies significantly by driver version
- Use `--cpu` if artifacts are observed
- Fedora users: Install `mesa-va-drivers-freeworld` for better codec support

### Intel Graphics (QSV)
- Generally reliable quality across generations
- Good performance/quality balance
- 10-bit support on newer processors (8th gen+)

### NVIDIA Graphics (NVENC)
- Highest quality and performance
- RTX 30/40 series support AV1 encoding
- Requires proper driver installation

### Apple Silicon (macOS)
- Excellent software encoding performance
- Native 10-bit HEVC support
- VideoToolbox hardware acceleration available
- Recommended: Use `--cpu` for maximum quality

## Troubleshooting

### Validation Errors / Typos

If you see an error like:

```
[ERROR] Invalid video codec: h265
[INFO] Supported codecs: hevc h264 av1 vp9
```

It means you provided a value not in the supported list. Double-check your spelling and use `--list-formats` or `--list-codecs` to see valid options.

### Hardware Detection Issues
```bash
# Check VAAPI functionality
vainfo --display drm --device /dev/dri/renderD128

# List available DRM devices
ls -la /dev/dri/

# Run with comprehensive debug output
cvrt --debug --vaapi .
```

### Permission Problems
```bash
# Add user to video group for GPU access
sudo usermod -a -G video $USER
# Log out and back in for changes to take effect
```

### Quality Issues (AMD VAAPI)
```bash
# Force high-quality software encoding
cvrt --cpu /path/to/videos
```

### Missing Dependencies
```bash
# Check all dependencies
cvrt --debug
# Will report missing tools and suggest installation commands
```

### Development Environment Issues
```bash
# Install development tools
./dev-tools.sh help

# Check if ShellCheck is available
./dev-tools.sh shellcheck

# Format code automatically
./dev-tools.sh format
```

## Supported Formats and Codecs

The script validates your choices for output format, video codec, and audio codec immediately when parsing arguments. If you provide an unsupported value (e.g., a typo like `h265` instead of `hevc`), the script will exit with a clear error message and list the supported options.

**Supported Output Formats:**
- mkv
- mp4
- mov
- webm

**Supported Video Codecs:**
- hevc (H.265)
- h264 (H.264)
- av1
- vp9

**Supported Audio Codecs:**
- aac
- ac3
- opus
- flac
- mp3

If you are unsure, you can always run:
```bash
cvrt --list-formats
cvrt --list-codecs
```
to see the current supported values.

## Supported Values Reference

### CLI Options and Valid Values

**Output Format (`--format`):**
- `mkv` - Matroska container (default)
- `mp4` - MP4 container
- `mov` - QuickTime container
- `webm` - WebM container

**Video Codec (`--codec`):**
- `hevc` - H.265/HEVC (default)
- `h264` - H.264/AVC
- `av1` - AV1 (newer cards)
- `vp9` - VP9

**Audio Codec (`--audio-codec`):**
- `aac` - AAC (default)
- `ac3` - AC3
- `opus` - Opus
- `flac` - FLAC
- `mp3` - MP3

**Quality (`--quality`):**
- Range: `1-1000`
- Default: `24`
- Lower values = higher quality
- Recommended: `18-28` for most content

**Scaling (`--scale`):**
- `none` - No scaling (default)
- `1080p` - Scale to 1920x1080
- `720p` - Scale to 1280x720
- `480p` - Scale to 854x480
- `4k` - Scale to 3840x2160
- `custom` - Use custom dimensions (requires CUSTOM_SCALE environment variable)

**Subtitle Mode (`--subtitles`):**
- `copy` - Preserve subtitles (default)
- `burn` - Burn subtitles into video
- `extract` - Extract subtitles to .srt files
- `none` - Remove subtitles

**Metadata Mode (`--metadata`):**
- `copy` - Preserve all metadata (default)
- `strip` - Remove all metadata
- `minimal` - Keep only essential metadata

**Thread Count (`--threads`):**
- `0` - Auto-detect (default)
- `1-64` - Specific thread count

### Configuration Keys and Default Values

**Quality Settings:**
- `QUALITY_PARAM`: `24` (video quality)
- `STEREO_BITRATE`: `"192k"` (audio bitrate)
- `MAX_BITRATE`: `"50M"` (max video bitrate)
- `BUFFER_SIZE`: `"100M"` (encoding buffer)

**Processing Defaults:**
- `DEFAULT_SCALE_MODE`: `"none"`
- `DEFAULT_DEINTERLACE`: `false`
- `DEFAULT_DENOISE`: `false`
- `DEFAULT_SHARPEN`: `false`
- `DEFAULT_SUBTITLE_MODE`: `"copy"`
- `DEFAULT_METADATA_MODE`: `"copy"`
- `DEFAULT_THREADS`: `0`

**Hardware Detection:**
- `MIN_RAM_DISK_GB`: `1`
- `RAM_DISK_PATH`: `"/dev/shm"`
- `HIGH_COMPLEXITY_THRESHOLD`: `8000000` (pixels)
- `MEDIUM_COMPLEXITY_THRESHOLD`: `2000000` (pixels)

**Encoder Settings:**
- `DEFAULT_PRESET`: `"medium"`
- `DEFAULT_TUNE`: `"film"`
- `DEFAULT_PROFILE`: `"main"`
- `DEFAULT_LEVEL`: `"4.1"`

**Subtitle Settings:**
- `DEFAULT_SUBTITLE_LANGUAGE`: `"eng"`

**Performance Settings:**
- `DEFAULT_BUFFER_SIZE_MB`: `100`
- `DEFAULT_MAX_MEMORY_GB`: `4`

## Output Format

The script provides cleaner, more informative output:

```
[INFO] GPU Video Converter v8.0
[INFO] Detecting hardware capabilities...
[HARDWARE] AMD 12-core | GPU: AMD dGPU
[INFO] Selected encoder: VAAPI
[INFO] Found 3 .mkv file(s) in: /media/videos

[INFO] Processing: movie1.mkv
    hevc 1920x1080 (10bit) | 2 audio tracks
[INFO]     Encoding with VAAPI
[INFO]     [SUCCESS] Created: movie1-converted.mkv

[RESULTS] Success: 2 | Failed: 0 | Skipped: 1 | Total: 3
[INFO] Conversion completed using: VAAPI
```

## Development

### Local CI Setup

The project includes a comprehensive local CI system that mirrors GitHub Actions:

```bash
# Run all local CI checks
./ci-local.sh

# The script will automatically run before each commit
# (pre-commit hook is already configured)
```

**Local CI checks include:**
- ShellCheck static analysis on all `.sh` files
- Bash syntax validation
- Script help output verification
- Trailing whitespace detection
- Missing newline at EOF checks

### Development Tools Setup

The project includes a comprehensive development toolkit for code quality and testing:

```bash
# Make development tools executable
chmod +x dev-tools.sh

# Run all quality checks
./dev-tools.sh all

# Check specific issues
./dev-tools.sh shellcheck    # Static analysis
./dev-tools.sh syntax        # Bash syntax validation
./dev-tools.sh whitespace    # Trailing whitespace check
./dev-tools.sh newlines      # Missing final newlines
./dev-tools.sh format        # Auto-format code
./dev-tools.sh test          # Basic functionality tests
```

### Testing Argument Parsing

Test the robust argument parsing with different option orders:

```bash
# Run argument parsing tests
./test_argument_parsing.sh
```

### Required Development Tools

**ShellCheck (Static Analysis):**
```bash
# Ubuntu/Debian
sudo apt install shellcheck

# Fedora/RHEL
sudo dnf install ShellCheck

# Arch Linux
sudo pacman -S shellcheck

# macOS
brew install shellcheck
```

**Additional Development Tools (Optional):**
```bash
# Code formatting and linting
npm install -g prettier
npm install -g markdownlint-cli

# Git hooks (pre-commit)
pip install pre-commit
```

### Code Quality Standards

The project follows these coding standards:
- **Bash Best Practices**: Proper error handling, variable quoting, associative arrays
- **Modular Design**: Clean separation of concerns across library files
- **Cross-Platform Compatibility**: Works on Linux, macOS (Intel/ARM)
- **Error Handling**: Comprehensive error checking and graceful fallbacks
- **Minimal Comments**: Self-descriptive code with comments only for non-obvious logic
- **Robust CLI**: Order-independent argument parsing with comprehensive validation

**Note:** ShellCheck may show style warnings (SC2155, SC2178, etc.) but these don't affect functionality. The project prioritizes compatibility and readability over strict style compliance.

### Testing Individual Components
```bash
# Test hardware detection only
source lib/utils.sh && source lib/hardware.sh
detect_all_hardware && display_hardware_summary

# Test video analysis
source lib/video_analysis.sh
declare -A info
analyze_video_file "test.mkv" info
```

### Adding New Encoders
1. Add capability detection in `lib/hardware.sh`
2. Add encoder configuration in `lib/encoders.sh`
3. Update scoring in `config/defaults.conf`
4. Add tests in `dev-tools.sh`
5. Update documentation

### Continuous Integration

The project includes GitHub Actions workflows for automated testing:
- **ShellCheck**: Static analysis of all shell scripts
- **Syntax Check**: Bash syntax validation
- **Basic Tests**: Functionality verification
- **Code Quality**: Trailing whitespace and newline checks

### Project Structure for Developers

```
video_conv/
├── .github/workflows/     # CI/CD pipelines
├── .shellcheckrc         # ShellCheck configuration
├── .git/hooks/pre-commit # Pre-commit hook
├── ci-local.sh          # Local CI script
├── dev-tools.sh         # Development utilities
├── test_argument_parsing.sh # Argument parsing tests
├── config/              # Configuration files
├── lib/                 # Core library modules
├── cvrt.sh             # Main script
└── README.md           # Documentation
```

## Safety Features

- **Non-destructive by default**: Creates `-converted.mkv` files unless `--replace` is used
- **Automatic fallbacks**: GPU encoding failure → software encoding
- **Input validation**: Comprehensive file and dependency checking
- **Clean error handling**: Proper cleanup and informative error messages
- **RAM disk management**: Automatic size checking to prevent system issues
- **Robust argument parsing**: Order-independent CLI with comprehensive validation

---

**Important:** Test with a few files before processing large libraries. The `--replace` option permanently overwrites original files.

## Notes

- The script uses symlink-aware path resolution, so it works correctly even when called through symlinks from system PATH directories
- All library and configuration files are automatically located relative to the actual script location
- Compatible with bash 3.2+ (including older macOS systems)
- Cross-platform support: Linux (x86_64, ARM), macOS (Intel, Apple Silicon)
- Development tools included for code quality maintenance
- Pre-commit hooks ensure code quality before each commit

## Contributing

1. **Fork the repository**
2. **Create a feature branch**: `git checkout -b feature/amazing-feature`
3. **Make your changes** following the coding standards
4. **Run quality checks**: `./ci-local.sh`
5. **Test your changes**: `./dev-tools.sh test`
6. **Commit your changes**: `git commit -m 'Add amazing feature'`
7. **Push to the branch**: `git push origin feature/amazing-feature`
8. **Open a Pull Request**

### Code Quality Checklist

Before submitting changes, ensure:
- [ ] All scripts pass ShellCheck: `./dev-tools.sh shellcheck`
- [ ] Bash syntax is valid: `./dev-tools.sh syntax`
- [ ] No trailing whitespace: `./dev-tools.sh whitespace`
- [ ] All files have final newlines: `./dev-tools.sh newlines`
- [ ] Basic tests pass: `./dev-tools.sh test`
- [ ] Local CI passes: `./ci-local.sh`
- [ ] Documentation is updated
- [ ] Cross-platform compatibility maintained
