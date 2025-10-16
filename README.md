## 🎞️ fx-upscale – Metal-Powered Video Upscaling

`fx-upscale` is a fast, Metal-based command-line tool for upscaling videos on macOS — optimized for Apple Silicon and modern GPUs.


### ✅ Features

* GPU-accelerated Metal processing for ultra-fast video upscaling  
* Automatic size calculation (keep aspect ratio if only width or height is given)  
* Supports `HEVC`, `H.264`, and `ProRes` codecs  
* Adjustable encoder quality (0-100)  
* Optional cropping before upscale  
* Smart fallback to ProRes for very large outputs  
* Speed-priority mode for faster encoding with minimal quality loss  

### 🚀 Installation

There are several ways to install `fx-upscale`

1. **Downloading the release package**

    The easiest way to install `fx-upscale` is to download the latest release package.
   After downloading and unpacking the archive (by double-clicking it), you’ll need to remove the quarantine attribute to satisfy Apple’s Gatekeeper and then copy the binary to a folder in your PATH - usually `/usr/local/bin`.

   Assuming the unpacked `fx-upscale` binary is in your **Downloads** folder, run

   ```bash
    cd ~/Downloads
    xattr -c fx-upscale
    sudo cp fx-upscale /usr/local/bin
    ```
    
3. **Compiling from source**

   Clone the repo
   
   ```bash
   git clone https://github.com/lisanet/fx-upscale.git
   ```

   Then navigate to the directory and build the source

    ```bash
    cd fx-upscale
    swift build -c release
    ```

    The resulting binary will be located in `.build/release/fx-upscale`. Finally, copy it into a directory in your PATH.

   ```bash
   cp .build/release/fx-upscale /usr/local/bin
   ```


### ⚙️ Usage

```
USAGE: fx-upscale -i input-file [options]

OPTIONS:
  -i, --input <input>     input video file to upscale. This option is required.
  -o, --output <output>   output video file path.
                          If not specified, ' upscaled' is appended to the input file name.
  -w, --width <width>     width in pixels of output video.
                          If only width is specified, height is calculated proportionally.
  -h, --height <height>   height in pixels of output video.
                          If only height is specified, width is calculated proportionally.
  -s, --scale <factor>    scale factor (e.g. 2.0). Overrides width/height. 
                          If neither width, height nor scale is given, the video is upscaled by factor 2.0
  -t, --target <preset>   Crop to target resolution <preset>. Applied before upscaling.
                          Presets are: 'fhd' (1920x1080), ' qhd' or 'wqhd' (2160x1440), '4k' or 'uhd' (3840x2160),  '8k' (7680x4320)
  -r, --crop <rect>       Crop rectangle 'width:height:left:top'. Applied before upscaling.
  -c, --codec <codec>     output codec: 'hevc', 'prores', or 'h264 (default: hevc)
  -q, --quality <quality> encoder quality 0 – 100. Applies to HEVC/H.264, ProRes is always lossless (default: 58)
  -g, --gop <size>        GOP size (default: let encoder decide the GOP size)
  -b, --bframes <bool>    use B-frames. You can use yes/no, true/false, 1/0 (default: yes)
  -p, --prio_speed <bool> prioritize speed over quality. You can use yes/no, true/false, 1/0 (default: yes)
  -y                      overwrite output file
  --quiet                 disable logging
  --version               Show the version.
  --help                  Show help information.```


### ℹ️ Note

> **Large outputs:**  
> Videos exceeding ~118 megapixels (≈14.5K × 8.1K) are automatically encoded as **ProRes 422** and saved as `.mov` for stability and compatibility.  
> This avoids known encoder limits with `H.264` and `HEVC`.


### 🌟 Quality

The `--quality` option accepts values between **0–100**, mapping directly to VideoToolbox’s `kVTCompressionPropertyKey_Quality`.
This behaves similarly to `CRF/CQ` controls used in `H.264/HEVC`.  
For **ProRes**, this parameter is ignored.

For best results, use `--quality` values above **58**. Values above 90 will only increase file size with little or no noticeable visual improvement. 

The recommended value is **58**.

### ⚡ Speed-priority Mode

The `--prio_speed` option sets VideoToolbox’s `kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality`. You can use yes/no, true/false or 1/0 to enable/disable this option. The default is enabled.

While this slightly reduces theoretical quality, the visual impact is minimal — and encoding speed improves dramatically, especially on Apple Silicon.  

### 🧪 Example

Upscale a 1080p video to 4K with very high quality. The default scaling factor is 2.0. Verbose output.

```bash
fx-upscale -i input.mp4 -q 80 -o output_4k.mov
```

Upscale a PAL video with 720x576 anamorphic encoded video to FullHD non-anamorph 1920x1080 with reasonable high quality (58) and using Speed-priority Mode and B-Frames. Be quiet, no info output

```bash
fx-upscale -i input.mp4 -width 1920 -height 1080 --quiet -o output_4k.mov
```

Upscale a 1080p letterboxed video, crop it before upscaling to 4K with aspect 2.39:1 and reasonable high quality, disabling Speed-priority Mode and using no B-Frames, verbose output

```bash
fx-upscale -i input.mp4 --crop 1920:800:0:0 -t 4k -q 60 -b 0 --prio_speed no -o output_4k.mov
```


### 📬 License

CC0 1.0 Universal – feel free to use, modify, and distribute.


### 🤝 Contributing

Contributions, bug reports, and feature requests are welcome. Please open an issue or submit a pull request if you have any improvements or suggestions.

### ⚠️ Disclaimer

`fx-upscale` is provided **'as is'** without any warranty.  
Use at your own risk and ensure you have backups of your original media.
