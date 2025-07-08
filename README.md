# GPU Video Converter v8.0 (Refactored)

A modular, maintainable Bash-based video converter with automatic hardware acceleration detection and optimization. Converts `.mkv` files to HEVC (H.265) using the best available encoder: NVIDIA NVENC, Intel QSV, AMD VAAPI, or software fallback.

## Features

* **Modular Architecture**: Clean separation of concerns across multiple library files
* **Intelligent Hardware Detection**: Automatic detection and scoring of available encoders
* **Multi-Platform GPU Support**:
  - NVIDIA NVENC (RTX/GTX series, AV1 support on newer cards)
  - Intel QSV (integrated and Arc discrete GPUs)
  - AMD VAAPI (APUs and discrete GPUs)
* **Configurable Settings**: Environment variable overrides and config files
* **Smart Audio Processing**: Preserves non-5.1 tracks, converts 5.1 to stereo when needed
* **RAM Disk Optimization**: Automatic use of `/dev/shm` when available
* **Comprehensive Error Handling**: Graceful fallbacks and detailed logging
* **10-bit HDR Support**: Hardware-accelerated when supported

## Project Structure

```
video-converter/
├── config/
│   └── defaults.conf      # Configuration settings
├── lib/
│   ├── utils.sh          # Logging and utility functions
│   ├── hardware.sh       # Hardware detection and capabilities
│   ├── encoders.sh       # Encoder selection and configuration
│   ├── video_analysis.sh # Video file analysis and metadata
│   └── audio_processing.sh # Audio conversion and encoding
├── cvrt.sh              # Main orchestration script
└── README.md
```

## Prerequisites

### Required Tools
```bash
ffmpeg ffprobe jq

# For VAAPI support (optional)
libva-utils
```

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

## Usage

### Basic Syntax
```bash
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
- `--help`, `-h`: Show usage information

### Examples

**Standard conversion (safe, non-destructive):**
```bash
./cvrt.sh /media/movies
```

**In-place replacement with debug output:**
```bash
./cvrt.sh --replace --debug .
```

**Force CPU encoding for maximum quality:**
```bash
./cvrt.sh --cpu /path/to/videos
```

**Auto-select best GPU encoder:**
```bash
./cvrt.sh --gpu /media/4k-content
```

## Configuration

### Environment Variables
Override default settings using environment variables:

```bash
export CVRT_QUALITY=22          # Quality parameter (lower = higher quality)
export CVRT_STEREO_BITRATE=256k # Audio bitrate for 5.1→stereo conversion
export CVRT_LOG_LEVEL=DEBUG     # Logging level: DEBUG, INFO, WARN, ERROR
```

### Quality Settings
- `20`: Very high quality, larger files
- `24`: Balanced quality/size (default)
- `28`: High compression, smaller files

### Advanced Configuration
Edit `config/defaults.conf` to modify:
- Encoder scoring priorities
- Hardware detection thresholds
- Temporary file management
- Buffer sizes and bitrates

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

## Troubleshooting

### Hardware Detection Issues
```bash
# Check VAAPI functionality
vainfo --display drm --device /dev/dri/renderD128

# List available DRM devices
ls -la /dev/dri/

# Run with comprehensive debug output
./cvrt.sh --debug --vaapi .
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
./cvrt.sh --cpu /path/to/videos
```

### Missing Dependencies
```bash
# Check all dependencies
./cvrt.sh --debug
# Will report missing tools and suggest installation commands
```

## Output Format

The refactored script provides cleaner, more informative output:

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

## Safety Features

- **Non-destructive by default**: Creates `-converted.mkv` files unless `--replace` is used
- **Automatic fallbacks**: GPU encoding failure → software encoding
- **Input validation**: Comprehensive file and dependency checking
- **Clean error handling**: Proper cleanup and informative error messages
- **RAM disk management**: Automatic size checking to prevent system issues

---

**Important:** Test with a few files before processing large libraries. The `--replace` option permanently overwrites original files.
